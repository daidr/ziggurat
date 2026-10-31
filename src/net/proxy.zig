//! The proxy a request goes through, as the user set it in the system's
//! settings, with its bypass list and automatic configuration (PAC files,
//! WPAD). `forUrl` decides for each request:
//!
//!  1. Loopback hosts (localhost, *.localhost, 127.0.0.0/8, ::1) are reached
//!     directly.
//!  2. When any of HTTP_PROXY, HTTPS_PROXY, ALL_PROXY or NO_PROXY (or its
//!     lowercase name) is set, the environment decides: HTTP_PROXY for `http`
//!     and `ws` URLs, HTTPS_PROXY for `https` and `wss`, ALL_PROXY for either
//!     when its own is unset, and NO_PROXY's hosts, domains and address
//!     ranges go direct. An explicit setting wins over the system's.
//!  3. Otherwise the system's settings for the URL do: WinHTTP's reading of
//!     the user's settings on Windows, with automatic detection and PAC
//!     files; GIO's default proxy resolver on Linux, which reads GNOME's
//!     settings, or KDE's and PAC files through libproxy. Where none
//!     answers, requests go direct.
//!
//! The system's answer for a scheme and host is kept for 5 seconds, so a
//! change of the settings applies to the requests that follow without
//! restarting the app.
//!
//! HTTP proxies and SOCKS5 are used: a SOCKS proxy of unknown version is
//! taken for SOCKS5; SOCKS4 and HTTPS proxies are skipped for the next one
//! the system lists. A proxy's password is sent only when the setting holds
//! it, as GNOME's settings and proxy URLs can.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const Kind = enum { http, socks5 };

/// One proxy server, stored inline: copying it copies its host and
/// credentials.
pub const Proxy = struct {
    kind: Kind,
    port: u16,
    host_len: u8 = 0,
    user_len: u8 = 0,
    password_len: u8 = 0,
    has_credentials: bool = false,
    host_buffer: [255]u8 = undefined,
    user_buffer: [255]u8 = undefined,
    password_buffer: [255]u8 = undefined,

    pub fn host(self: *const Proxy) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// The user and password to authenticate with, or null.
    pub fn credentials(self: *const Proxy) ?struct { user: []const u8, password: []const u8 } {
        if (!self.has_credentials) return null;
        return .{ .user = self.user_buffer[0..self.user_len], .password = self.password_buffer[0..self.password_len] };
    }

    pub fn eql(a: *const Proxy, b: *const Proxy) bool {
        const ca = a.credentials();
        const cb = b.credentials();
        if ((ca == null) != (cb == null)) return false;
        if (ca) |x| if (!std.mem.eql(u8, x.user, cb.?.user) or !std.mem.eql(u8, x.password, cb.?.password)) return false;
        return a.kind == b.kind and a.port == b.port and std.ascii.eqlIgnoreCase(a.host(), b.host());
    }

    /// Parses one proxy: `http://host:port`, `socks5://user:pass@host:port`,
    /// or `host:port`, taken for HTTP. Null for a proxy that cannot be used,
    /// or for `direct://`.
    pub fn parse(text: []const u8) ?Proxy {
        return switch (parseEntry(text)) {
            .proxy => |value| value,
            else => null,
        };
    }
};

/// Where a request goes: the decision of `forUrl`, no proxy, or a given one.
pub const Choice = union(enum) {
    system,
    direct,
    proxy: Proxy,

    /// The proxy for `uri`, or null to connect directly.
    pub fn resolve(self: *const Choice, uri: std.Uri) ?Proxy {
        return switch (self.*) {
            .system => forUrl(uri),
            .direct => null,
            .proxy => |value| value,
        };
    }
};

/// The proxy for `uri` (`http`, `https`, `ws` or `wss`), or null to connect
/// directly. Safe from any thread; it may block while the system runs a PAC
/// file, so call it on a worker.
pub fn forUrl(uri: std.Uri) ?Proxy {
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = (std.Io.net.HostName.fromUri(uri, &host_buffer) catch return null).bytes;
    if (isLoopback(host_name)) return null;
    const secure = isSecure(uri.scheme);
    var env_buffer: [4096]u8 = undefined;
    var env: Environment = .{ .buffer = &env_buffer };
    if (env.any()) return fromEnvironment(&env, secure, host_name, uri.port orelse defaultPort(secure));
    return cached(secure, host_name, uri.port orelse defaultPort(secure));
}

fn isSecure(scheme: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss");
}

fn defaultPort(secure: bool) u16 {
    return if (secure) 443 else 80;
}

pub fn isLoopback(host_name: []const u8) bool {
    var lower_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    if (host_name.len > lower_buffer.len) return false;
    const host_value = std.ascii.lowerString(&lower_buffer, trimHost(host_name));
    if (std.mem.eql(u8, host_value, "localhost") or std.mem.endsWith(u8, host_value, ".localhost")) return true;
    const address = parseIp(host_value) orelse return false;
    return switch (address) {
        .v4 => |bytes| bytes[0] == 127,
        .v6 => |bytes| (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) or (isMapped(bytes) and bytes[12] == 127),
    };
}

fn trimHost(host_name: []const u8) []const u8 {
    var value = host_name;
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') value = value[1 .. value.len - 1];
    if (std.mem.endsWith(u8, value, ".")) value = value[0 .. value.len - 1];
    return value;
}

// Addresses.

const Ip = union(enum) { v4: [4]u8, v6: [16]u8 };

fn parseIp(text: []const u8) ?Ip {
    const value = trimHost(text);
    if (std.Io.net.Ip4Address.parse(value, 0)) |address| {
        return .{ .v4 = address.bytes };
    } else |_| {}
    if (std.mem.indexOfScalar(u8, value, '%') != null) return null;
    if (std.Io.net.Ip6Address.parse(value, 0)) |address| return .{ .v6 = address.bytes } else |_| return null;
}

fn isMapped(bytes: [16]u8) bool {
    return std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff;
}

/// An IPv4-mapped IPv6 address as IPv4.
fn unmap(address: Ip) Ip {
    return switch (address) {
        .v6 => |bytes| if (isMapped(bytes)) .{ .v4 = bytes[12..16].* } else address,
        .v4 => address,
    };
}

const Prefix = struct {
    address: Ip,
    bits: u8,

    fn parse(text: []const u8) ?Prefix {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
        const address = parseIp(text[0..slash]) orelse return null;
        const bits = std.fmt.parseInt(u8, text[slash + 1 ..], 10) catch return null;
        if (bits > @as(u8, if (address == .v4) 32 else 128)) return null;
        return .{ .address = address, .bits = bits };
    }

    fn contains(self: Prefix, candidate: Ip) bool {
        const a: []const u8, const b: []const u8 = switch (self.address) {
            .v4 => |*bytes| switch (candidate) {
                .v4 => |*other| .{ bytes, other },
                .v6 => return false,
            },
            .v6 => |*bytes| switch (candidate) {
                .v6 => |*other| .{ bytes, other },
                .v4 => return false,
            },
        };
        const whole = self.bits / 8;
        if (!std.mem.eql(u8, a[0..whole], b[0..whole])) return false;
        const rest: u3 = @intCast(self.bits % 8);
        if (rest == 0) return true;
        const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rest));
        return a[whole] & mask == b[whole] & mask;
    }
};

// Proxy lists.

const Entry = union(enum) { proxy: Proxy, direct, unusable };

/// One proxy of a list, as GIO and PAC answers give them.
fn parseEntry(raw: []const u8) Entry {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(text, "direct://") or std.ascii.eqlIgnoreCase(text, "direct")) return .direct;
    if (text.len == 0) return .unusable;
    const scheme_end = std.mem.indexOf(u8, text, "://");
    const scheme = if (scheme_end) |end| text[0..end] else "http";
    const kind: Kind = if (std.ascii.eqlIgnoreCase(scheme, "http"))
        .http
    else if (std.ascii.eqlIgnoreCase(scheme, "socks5") or std.ascii.eqlIgnoreCase(scheme, "socks5h") or std.ascii.eqlIgnoreCase(scheme, "socks"))
        .socks5
    else
        return .unusable; // https, socks4, socks4a, ftp...
    const rest = if (scheme_end) |end| text[end + 3 ..] else text;
    var authority_buffer: [1024]u8 = undefined;
    const authority = std.fmt.bufPrint(&authority_buffer, "//{s}", .{rest}) catch return .unusable;
    const uri = std.Uri.parseAfterScheme("http", authority) catch return .unusable;
    var proxy: Proxy = .{ .kind = kind, .port = uri.port orelse if (kind == .http) 80 else 1080 };
    const host_component = uri.host orelse return .unusable;
    var host_name = copyComponent(host_component, &proxy.host_buffer) orelse return .unusable;
    if (host_name.len >= 2 and host_name[0] == '[' and host_name[host_name.len - 1] == ']') {
        std.mem.copyForwards(u8, &proxy.host_buffer, host_name[1 .. host_name.len - 1]);
        host_name = proxy.host_buffer[0 .. host_name.len - 2];
    }
    if (host_name.len == 0) return .unusable;
    proxy.host_len = @intCast(host_name.len);
    if (uri.user) |user| {
        const value = copyComponent(user, &proxy.user_buffer) orelse return .unusable;
        proxy.user_len = @intCast(value.len);
        if (uri.password) |password| {
            const secret = copyComponent(password, &proxy.password_buffer) orelse return .unusable;
            proxy.password_len = @intCast(secret.len);
        }
        proxy.has_credentials = true;
    }
    return .{ .proxy = proxy };
}

/// A URL component, percent-decoded, copied into `out`.
fn copyComponent(component: std.Uri.Component, out: []u8) ?[]const u8 {
    var buffer: [255]u8 = undefined;
    const value = component.toRaw(&buffer) catch return null;
    if (value.len > out.len) return null;
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}

/// The first proxy of a list that can be used, or null for a direct
/// connection: `direct://` comes first, or no proxy can be used.
pub fn firstSupported(list: []const []const u8) ?Proxy {
    for (list) |item| switch (parseEntry(item)) {
        .proxy => |value| return value,
        .direct => return null,
        .unusable => {},
    };
    return null;
}

/// The proxy of a Windows proxy list for URLs of a scheme: `host:port` for
/// every scheme, or per scheme as `http=host:port;https=host:port;
/// socks=host:port`, where a scheme without its own proxy uses the SOCKS
/// one. Entries are separated by semicolons or spaces; the first that
/// applies wins.
pub fn windowsProxy(list: []const u8, secure: bool) ?Proxy {
    const scheme = if (secure) "https" else "http";
    var all: ?Proxy = null;
    var socks: ?Proxy = null;
    var entries = std.mem.tokenizeAny(u8, list, "; \t\r\n");
    while (entries.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse {
            if (all == null) all = windowsEntry(entry, "http");
            continue;
        };
        const key = std.mem.trim(u8, entry[0..equals], " \t");
        const value = entry[equals + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, scheme)) {
            if (windowsEntry(value, "http")) |proxy| return proxy;
        } else if (std.ascii.eqlIgnoreCase(key, "socks") and socks == null) {
            socks = windowsEntry(value, "socks5");
        }
    }
    return all orelse socks;
}

fn windowsEntry(raw: []const u8, scheme: []const u8) ?Proxy {
    const text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0) return null;
    if (std.mem.indexOf(u8, text, "://") != null) return Proxy.parse(text);
    var buffer: [600]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}://{s}", .{ scheme, text }) catch return null;
    return Proxy.parse(full);
}

/// The proxy of a Windows proxy list and bypass list for a host.
pub fn windowsStatic(proxy_list: []const u8, bypass: []const u8, secure: bool, host_name: []const u8) ?Proxy {
    if (proxy_list.len == 0 or windowsBypassed(bypass, host_name)) return null;
    return windowsProxy(proxy_list, secure);
}

/// Whether a Windows bypass list sends a host direct: entries separated by
/// semicolons or spaces, each a host name or an IP address with `*`
/// wildcards (`*.example.com`, `10.*`), a domain with a leading dot
/// (`.example.com`), an address prefix (`10.0.0.0/8`), or `<local>`, the
/// host names without a dot.
pub fn windowsBypassed(list: []const u8, raw_host: []const u8) bool {
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    if (raw_host.len > host_buffer.len) return false;
    const host_name = std.ascii.lowerString(&host_buffer, trimHost(raw_host));
    if (host_name.len == 0) return false;
    const address = parseIp(host_name);
    var entries = std.mem.tokenizeAny(u8, list, "; \t\r\n");
    while (entries.next()) |raw_entry| {
        var entry_buffer: [512]u8 = undefined;
        if (raw_entry.len > entry_buffer.len) continue;
        var entry: []const u8 = std.ascii.lowerString(&entry_buffer, raw_entry);
        if (std.mem.indexOf(u8, entry, "://")) |index| entry = entry[index + 3 ..];
        if (std.mem.eql(u8, entry, "<local>")) {
            if (address == null and std.mem.indexOfScalar(u8, host_name, '.') == null) return true;
        } else if (std.mem.startsWith(u8, entry, "<")) {
            // <-loopback>; loopback hosts never reach here.
        } else if (std.mem.indexOfScalar(u8, entry, '/') != null) {
            const prefix = Prefix.parse(entry) orelse continue;
            if (address) |value| if (prefix.contains(unmap(value))) return true;
        } else {
            entry = stripPort(entry);
            var pattern_buffer: [513]u8 = undefined;
            const pattern = if (std.mem.startsWith(u8, entry, ".")) std.fmt.bufPrint(&pattern_buffer, "*{s}", .{entry}) catch continue else entry;
            if (matchGlob(pattern, host_name)) return true;
        }
    }
    return false;
}

/// `host:port`, `[v6]:port` or `[v6]` without its port and brackets; any
/// other text as it is.
fn stripPort(entry: []const u8) []const u8 {
    if (std.mem.startsWith(u8, entry, "[")) {
        const close = std.mem.indexOfScalar(u8, entry, ']') orelse return entry;
        return entry[1..close];
    }
    const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return entry;
    if (std.mem.indexOfScalar(u8, entry[0..colon], ':') != null) return entry; // a bare IPv6 address
    _ = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch return entry;
    return entry[0..colon];
}

/// Whether `text` matches `pattern`, where `*` stands for any characters,
/// dots included.
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, text);
    if (!std.mem.startsWith(u8, text, pattern[0..star])) return false;
    const after = pattern[star + 1 ..];
    const rest = text[star..];
    var index: usize = 0;
    while (index <= rest.len) : (index += 1) if (matchGlob(after, rest[index..])) return true;
    return false;
}

// The environment.

const env_names = [_][]const u8{ "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy" };

/// Reads variables into a fixed buffer; each `get` reuses it.
pub const Environment = struct {
    buffer: []u8,
    /// Replaces the process environment, for tests.
    lookup: ?*const fn (name: []const u8) ?[]const u8 = null,

    pub fn get(self: *Environment, name: []const u8) ?[]const u8 {
        if (self.lookup) |lookup| return nonEmpty(lookup(name));
        if (builtin.os.tag == .windows) {
            var fixed: std.heap.FixedBufferAllocator = .init(self.buffer);
            return nonEmpty(zio.getEnvVarOwned(fixed.allocator(), name) catch null);
        }
        if (!builtin.link_libc and builtin.os.tag != .linux) return null;
        return nonEmpty(zio.getenv(name));
    }

    fn nonEmpty(value: ?[]const u8) ?[]const u8 {
        const text = value orelse return null;
        return if (text.len == 0) null else text;
    }

    pub fn any(self: *Environment) bool {
        for (env_names) |name| if (self.get(name) != null) return true;
        return false;
    }

    /// The first set variable of `names`, copied into `out`.
    fn first(self: *Environment, names: []const []const u8, out: []u8) ?[]const u8 {
        for (names) |name| if (self.get(name)) |value| {
            if (value.len > out.len) return null;
            @memcpy(out[0..value.len], value);
            return out[0..value.len];
        };
        return null;
    }
};

/// The environment's proxy for a URL of a host, for `http`/`ws` or, when
/// `secure`, `https`/`wss`.
pub fn fromEnvironment(env: *Environment, secure: bool, host_name: []const u8, port: u16) ?Proxy {
    var no_proxy_buffer: [4096]u8 = undefined;
    if (env.first(&.{ "NO_PROXY", "no_proxy" }, &no_proxy_buffer)) |list| if (noProxy(list, host_name, port)) return null;
    var value_buffer: [1024]u8 = undefined;
    const names: []const []const u8 = if (secure) &.{ "HTTPS_PROXY", "https_proxy" } else &.{ "HTTP_PROXY", "http_proxy" };
    const value = env.first(names, &value_buffer) orelse env.first(&.{ "ALL_PROXY", "all_proxy" }, &value_buffer) orelse return null;
    return Proxy.parse(value);
}

/// Whether a NO_PROXY list sends a host direct: `*` for every host, or
/// comma-separated entries, each an IP address or prefix, or a domain that
/// matches itself and its subdomains (`.example.com` and `*.example.com`
/// only the subdomains), any of them with a port that must match too.
pub fn noProxy(list: []const u8, raw_host: []const u8, port: u16) bool {
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    if (raw_host.len > host_buffer.len) return false;
    const host_name = std.ascii.lowerString(&host_buffer, trimHost(raw_host));
    const address = parseIp(host_name);
    var entries = std.mem.tokenizeAny(u8, list, ", \t");
    while (entries.next()) |raw_entry| {
        var entry_buffer: [512]u8 = undefined;
        if (raw_entry.len > entry_buffer.len) continue;
        const entry = std.ascii.lowerString(&entry_buffer, raw_entry);
        if (std.mem.eql(u8, entry, "*")) return true;
        if (Prefix.parse(entry)) |prefix| {
            if (address) |value| if (prefix.contains(unmap(value))) return true;
            continue;
        }
        var pattern = stripPort(entry);
        var want_port: ?u16 = null;
        if (pattern.len != entry.len) {
            const colon = std.mem.lastIndexOfScalar(u8, entry, ':').?;
            want_port = std.fmt.parseInt(u16, entry[colon + 1 ..], 10) catch null;
        }
        if (want_port) |value| if (value != port) continue;
        if (parseIp(pattern)) |entry_address| {
            if (address) |value| if (std.meta.eql(unmap(entry_address), unmap(value))) return true;
            continue;
        }
        if (std.mem.startsWith(u8, pattern, "*.")) pattern = pattern[1..];
        if (std.mem.startsWith(u8, pattern, ".")) {
            if (std.mem.endsWith(u8, host_name, pattern)) return true;
        } else if (std.mem.eql(u8, host_name, pattern) or (std.mem.endsWith(u8, host_name, pattern) and host_name.len > pattern.len and host_name[host_name.len - pattern.len - 1] == '.')) {
            return true;
        }
    }
    return false;
}

// The system's answers, kept for a while.

const ttl_ms = 5 * std.time.ms_per_s;
const cache_capacity = 32;

const CacheEntry = struct {
    key_len: u16 = 0,
    key: [std.Io.net.HostName.max_len + 16]u8 = undefined,
    proxy: ?Proxy = null,
    until: i64 = 0,
};

var cache_mutex: zio.Mutex = .{};
var cache_entries: [cache_capacity]CacheEntry = @splat(.{});
var cache_len: usize = 0;

/// Replaced by tests.
var system_resolver: *const fn (secure: bool, host_name: []const u8, port: u16) ?Proxy = system;
var clock: *const fn () i64 = zio.milliTimestamp;

fn cached(secure: bool, host_name: []const u8, port: u16) ?Proxy {
    var key_buffer: [std.Io.net.HostName.max_len + 16]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}://{s}:{d}", .{ if (secure) "https" else "http", host_name, port }) catch return null;
    const now = clock();
    {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        for (cache_entries[0..cache_len]) |*entry| if (std.ascii.eqlIgnoreCase(entry.key[0..entry.key_len], key) and now < entry.until) return entry.proxy;
    }
    const answer = system_resolver(secure, host_name, port);
    cache_mutex.lock();
    defer cache_mutex.unlock();
    const slot = for (cache_entries[0..cache_len]) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.key[0..entry.key_len], key)) break entry;
    } else slot: {
        if (cache_len == cache_capacity) cache_len = 0;
        cache_len += 1;
        break :slot &cache_entries[cache_len - 1];
    };
    @memcpy(slot.key[0..key.len], key);
    slot.key_len = @intCast(key.len);
    slot.proxy = answer;
    slot.until = now + ttl_ms;
    return answer;
}

fn system(secure: bool, host_name: []const u8, port: u16) ?Proxy {
    var url_buffer: [std.Io.net.HostName.max_len + 32]u8 = undefined;
    const bracket = std.mem.indexOfScalar(u8, host_name, ':') != null and !std.mem.startsWith(u8, host_name, "[");
    const url = std.fmt.bufPrint(&url_buffer, "{s}://{s}{s}{s}:{d}/", .{ if (secure) "https" else "http", if (bracket) "[" else "", host_name, if (bracket) "]" else "", port }) catch return null;
    return switch (builtin.os.tag) {
        .linux => if (builtin.link_libc) @import("proxy_linux.zig").system(url) else null,
        .windows => @import("proxy_windows.zig").system(url, secure, host_name),
        else => null,
    };
}

// Tests.

fn testEnvironment(comptime values: []const [2][]const u8) *const fn ([]const u8) ?[]const u8 {
    return struct {
        fn get(name: []const u8) ?[]const u8 {
            inline for (values) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
            return null;
        }
    }.get;
}

test "proxy entries parse with their kind, port and credentials" {
    const proxy = Proxy.parse("http://user:p%40ss@proxy.example:3128").?;
    try std.testing.expectEqual(Kind.http, proxy.kind);
    try std.testing.expectEqualStrings("proxy.example", proxy.host());
    try std.testing.expectEqual(@as(u16, 3128), proxy.port);
    try std.testing.expectEqualStrings("user", proxy.credentials().?.user);
    try std.testing.expectEqualStrings("p@ss", proxy.credentials().?.password);
    try std.testing.expectEqual(Kind.socks5, Proxy.parse("socks://10.0.0.1:1080").?.kind);
    try std.testing.expectEqual(Kind.socks5, Proxy.parse("SOCKS5H://h").?.kind);
    try std.testing.expectEqual(@as(u16, 1080), Proxy.parse("socks5://h").?.port);
    try std.testing.expectEqual(@as(u16, 80), Proxy.parse("h").?.port);
    try std.testing.expectEqualStrings("::1", Proxy.parse("http://[::1]:8080").?.host());
    try std.testing.expect(Proxy.parse("plain:8080").?.credentials() == null);
    try std.testing.expect(Proxy.parse("socks4://h:1080") == null);
    try std.testing.expect(Proxy.parse("https://h:443") == null);
    try std.testing.expect(Proxy.parse("direct://") == null);
}

test "proxy lists take the first usable proxy unless direct comes first" {
    try std.testing.expectEqualStrings("b", firstSupported(&.{ "socks4://a:1", "http://b:2", "direct://" }).?.host());
    try std.testing.expect(firstSupported(&.{ "direct://", "http://b:2" }) == null);
    try std.testing.expect(firstSupported(&.{"ftp://a:1"}) == null);
}

test "windows proxy lists pick per scheme, then any, then SOCKS" {
    try std.testing.expectEqualStrings("p", windowsProxy("p:8080", true).?.host());
    try std.testing.expectEqualStrings("s", windowsProxy("http=h:1;https=s:2", true).?.host());
    try std.testing.expectEqualStrings("h", windowsProxy("http=h:1;https=s:2", false).?.host());
    const socks = windowsProxy("http=h:1 socks=k:9", true).?;
    try std.testing.expectEqual(Kind.socks5, socks.kind);
    try std.testing.expectEqualStrings("k", socks.host());
    try std.testing.expectEqual(@as(u16, 9), socks.port);
    try std.testing.expect(windowsProxy("ftp=f:21", true) == null);
    try std.testing.expect(windowsStatic("", "", true, "a.com") == null);
    try std.testing.expect(windowsStatic("p:1", "*.corp", true, "x.corp") == null);
}

test "windows bypass lists match hosts, domains, prefixes and local names" {
    try std.testing.expect(windowsBypassed("<local>", "intranet"));
    try std.testing.expect(!windowsBypassed("<local>", "intranet.corp"));
    try std.testing.expect(!windowsBypassed("<local>", "10.0.0.1"));
    try std.testing.expect(windowsBypassed("*.example.com", "a.b.example.com"));
    try std.testing.expect(windowsBypassed(".example.com", "a.example.com"));
    try std.testing.expect(!windowsBypassed(".example.com", "example.com"));
    try std.testing.expect(windowsBypassed("10.*", "10.1.2.3"));
    try std.testing.expect(windowsBypassed("10.0.0.0/8; other", "10.200.0.1"));
    try std.testing.expect(!windowsBypassed("10.0.0.0/8", "11.0.0.1"));
    try std.testing.expect(windowsBypassed("HOST.example:8080", "host.EXAMPLE"));
    try std.testing.expect(windowsBypassed("http://site.test", "site.test"));
    try std.testing.expect(windowsBypassed("[fe80::1]", "fe80::1"));
    try std.testing.expect(windowsBypassed("fd00::/8", "[fd12::5]"));
    try std.testing.expect(!windowsBypassed("<-loopback>", "a.com"));
    try std.testing.expect(matchGlob("a*c*e", "abcde"));
    try std.testing.expect(!matchGlob("a*c", "abd"));
}

test "NO_PROXY matches hosts, subdomains, addresses, prefixes and ports" {
    try std.testing.expect(noProxy("*", "anything", 80));
    try std.testing.expect(noProxy("example.com", "example.com", 443));
    try std.testing.expect(noProxy("example.com", "a.example.com", 443));
    try std.testing.expect(!noProxy("example.com", "badexample.com", 443));
    try std.testing.expect(noProxy(".example.com", "a.example.com", 443));
    try std.testing.expect(!noProxy(".example.com", "example.com", 443));
    try std.testing.expect(!noProxy("*.example.com", "example.com", 443));
    try std.testing.expect(noProxy("a.com, example.com:8443", "example.com", 8443));
    try std.testing.expect(!noProxy("example.com:8443", "example.com", 443));
    try std.testing.expect(noProxy("192.168.0.0/16", "192.168.4.4", 80));
    try std.testing.expect(noProxy("10.1.1.1", "10.1.1.1", 80));
    try std.testing.expect(noProxy("[::2]:80", "::2", 80));
    try std.testing.expect(!noProxy("10.1.1.1", "10.1.1.2", 80));
}

test "the environment decides once any proxy variable is set" {
    var buffer: [256]u8 = undefined;
    var env: Environment = .{ .buffer = &buffer, .lookup = testEnvironment(&.{ .{ "HTTP_PROXY", "plain:1" }, .{ "https_proxy", "socks5://secure:2" }, .{ "NO_PROXY", "skip.test" } }) };
    try std.testing.expect(env.any());
    try std.testing.expectEqualStrings("plain", fromEnvironment(&env, false, "a.test", 80).?.host());
    try std.testing.expectEqual(Kind.socks5, fromEnvironment(&env, true, "a.test", 443).?.kind);
    try std.testing.expect(fromEnvironment(&env, true, "x.skip.test", 443) == null);
    var all: Environment = .{ .buffer = &buffer, .lookup = testEnvironment(&.{.{ "ALL_PROXY", "socks5://every:5" }}) };
    try std.testing.expectEqualStrings("every", fromEnvironment(&all, true, "a.test", 443).?.host());
    var none: Environment = .{ .buffer = &buffer, .lookup = testEnvironment(&.{.{ "NO_PROXY", "x" }}) };
    try std.testing.expect(none.any());
    try std.testing.expect(fromEnvironment(&none, false, "a.test", 80) == null);
    var empty: Environment = .{ .buffer = &buffer, .lookup = testEnvironment(&.{.{ "HTTP_PROXY", "" }}) };
    try std.testing.expect(!empty.any());
}

test "loopback hosts are never proxied" {
    for ([_][]const u8{ "localhost", "LOCALHOST.", "app.localhost", "127.0.0.1", "127.9.9.9", "::1", "[::1]", "::ffff:127.0.0.1" }) |host_name| try std.testing.expect(isLoopback(host_name));
    for ([_][]const u8{ "localhost.example", "128.0.0.1", "::2", "example.com" }) |host_name| try std.testing.expect(!isLoopback(host_name));
}

test "the system's answers are kept for five seconds per scheme and host" {
    const Fake = struct {
        var calls: usize = 0;
        var now: i64 = 1000;
        fn resolve(secure: bool, host_name: []const u8, port: u16) ?Proxy {
            _ = port;
            calls += 1;
            if (std.mem.eql(u8, host_name, "direct.test")) return null;
            return Proxy.parse(if (secure) "http://secure:1" else "http://plain:1");
        }
        fn time() i64 {
            return now;
        }
    };
    const saved_resolver = system_resolver;
    const saved_clock = clock;
    defer {
        system_resolver = saved_resolver;
        clock = saved_clock;
        cache_len = 0;
    }
    system_resolver = Fake.resolve;
    clock = Fake.time;
    cache_len = 0;
    try std.testing.expectEqualStrings("secure", cached(true, "a.test", 443).?.host());
    try std.testing.expectEqualStrings("secure", cached(true, "A.test", 443).?.host());
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expectEqualStrings("plain", cached(false, "a.test", 80).?.host());
    try std.testing.expect(cached(false, "direct.test", 80) == null);
    try std.testing.expect(cached(false, "direct.test", 80) == null);
    try std.testing.expectEqual(@as(usize, 3), Fake.calls);
    Fake.now += ttl_ms;
    _ = cached(true, "a.test", 443);
    try std.testing.expectEqual(@as(usize, 4), Fake.calls);
    for (0..cache_capacity + 3) |index| {
        var name: [16]u8 = undefined;
        _ = cached(true, std.fmt.bufPrint(&name, "h{d}.test", .{index}) catch unreachable, 443);
    }
    try std.testing.expect(cache_len <= cache_capacity);
}
