//! HTTP sign-in and server certificate errors of a View's pages
//! (Options.http_auth, Options.certificate_errors): what the engines tell,
//! in the words the app reads.
const std = @import("std");

pub const Scheme = enum { basic, digest, ntlm, negotiate };

/// A server, or a proxy, asks for a user name and a password before it
/// serves the page or something the page loads.
pub const Challenge = struct {
    /// The server's host and port, or the proxy's.
    host: []const u8,
    port: u16,
    /// The protection space the server named, empty for none: one server
    /// can ask for the credentials of several.
    realm: []const u8,
    scheme: Scheme,
    /// A proxy asks rather than the server. WebView2 does not tell: false
    /// on Windows, where host is then the proxy's.
    proxy: bool,
};

/// Borrowed until the handler returns; the engine copies them and keeps
/// those the server accepts for the session, for that server and realm.
pub const Credentials = struct { username: []const u8, password: []const u8 };

/// A server's certificate that does not verify.
pub const CertificateError = struct {
    /// What was loading: the page, or what it loads (Windows only).
    uri: []const u8,
    /// The server's host in uri, a name or an IP address.
    host: []const u8,
    /// What is wrong with the certificate, for logs and messages.
    reason: []const u8,
    /// The server's certificate, DER-encoded; empty when the engine gave
    /// none. Compare it, or its hash, with the one the app expects.
    certificate: []const u8,
};

pub const limits = struct {
    /// Longer credentials are refused, and the sign-in canceled.
    pub const credential_bytes = 1024;
    pub const certificate_bytes = 65536;
};

/// The scheme of an engine's name for it, null for one apps cannot answer
/// with a password (client certificates, server trust).
pub fn schemeNamed(name: []const u8) ?Scheme {
    for (std.enums.values(Scheme)) |scheme| if (std.ascii.eqlIgnoreCase(name, @tagName(scheme))) return scheme;
    return null;
}

/// WebKitAuthenticationScheme's HTTP schemes.
pub fn webkitScheme(value: u32) ?Scheme {
    return switch (value) {
        1, 2 => .basic, // DEFAULT, HTTP_BASIC
        3 => .digest,
        5 => .ntlm,
        6 => .negotiate,
        else => null,
    };
}

pub const Parsed = struct { scheme: []const u8, realm: []const u8, realm_storage: [512]u8 = undefined };

/// The scheme and the realm of a WWW-Authenticate challenge:
/// `Basic realm="intranet", charset="UTF-8"` is "Basic" and "intranet".
/// A realm longer than its storage is cut.
pub fn parseChallenge(challenge: []const u8, out: *Parsed) void {
    var s = std.mem.trim(u8, challenge, " \t");
    const end = std.mem.indexOfAny(u8, s, " \t,") orelse s.len;
    out.scheme = s[0..end];
    out.realm = "";
    s = s[end..];
    while (s.len != 0) {
        s = std.mem.trimStart(u8, s, " \t,");
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse return;
        const name = std.mem.trim(u8, s[0..eq], " \t");
        s = std.mem.trimStart(u8, s[eq + 1 ..], " \t");
        var length: usize = 0;
        if (s.len != 0 and s[0] == '"') {
            var i: usize = 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
                if (length < out.realm_storage.len) out.realm_storage[length] = s[i];
                length += 1;
            }
            s = s[@min(i + 1, s.len)..];
        } else {
            const value_end = std.mem.indexOfAny(u8, s, ", \t") orelse s.len;
            length = @min(value_end, out.realm_storage.len);
            @memcpy(out.realm_storage[0..length], s[0..length]);
            s = s[value_end..];
        }
        if (std.ascii.eqlIgnoreCase(name, "realm")) {
            out.realm = out.realm_storage[0..@min(length, out.realm_storage.len)];
            return;
        }
    }
}

pub const Authority = struct { host: []const u8, port: u16 };

/// The host and port of an absolute http(s) URI, the default port when it
/// names none; brackets stay off an IPv6 address.
pub fn authority(uri: []const u8) ?Authority {
    const separator = std.mem.indexOf(u8, uri, "://") orelse return null;
    const scheme = uri[0..separator];
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) 443 else if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) 80 else return null;
    var rest = uri[separator + 3 ..];
    rest = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    var host = rest;
    var port_text: []const u8 = "";
    if (rest.len != 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        host = rest[1..close];
        const after = rest[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return null;
            port_text = after[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        host = rest[0..colon];
        port_text = rest[colon + 1 ..];
    }
    if (host.len == 0) return null;
    const port = if (port_text.len == 0) default_port else std.fmt.parseInt(u16, port_text, 10) catch return null;
    return .{ .host = host, .port = port };
}

/// COREWEBVIEW2_WEB_ERROR_STATUS's certificate errors.
pub fn webview2Reason(status: i32) []const u8 {
    return switch (status) {
        1 => "the certificate does not match the host",
        2 => "the certificate expired",
        3 => "the client certificate contains errors",
        4 => "the certificate was revoked",
        5 => "the certificate is invalid",
        else => "the certificate does not verify",
    };
}

/// The first of GTlsCertificateFlags a certificate failed with.
pub fn gtlsReason(flags: u32) []const u8 {
    const reasons = [_][]const u8{
        "the certificate's issuer is not known",
        "the certificate does not match the host",
        "the certificate is not valid yet",
        "the certificate expired",
        "the certificate was revoked",
        "the certificate's algorithm is insecure",
        "the certificate is invalid",
    };
    for (reasons, 0..) |reason, i| if (flags & (@as(u32, 1) << @intCast(i)) != 0) return reason;
    return "the certificate does not verify";
}

/// The DER of the first certificate of PEM text, written to out; null when
/// there is none or it does not fit.
pub fn pemCertificate(pem: []const u8, out: []u8) ?[]u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const start = (std.mem.indexOf(u8, pem, begin) orelse return null) + begin.len;
    const stop = start + (std.mem.indexOf(u8, pem[start..], "-----END") orelse return null);
    var length: usize = 0;
    var quad: [4]u8 = undefined;
    var filled: usize = 0;
    const decoder = std.base64.standard.Decoder;
    for (pem[start..stop]) |byte| {
        if (byte == '\r' or byte == '\n' or byte == ' ' or byte == '\t') continue;
        quad[filled] = byte;
        filled += 1;
        if (filled < 4) continue;
        filled = 0;
        const size = decoder.calcSizeForSlice(&quad) catch return null;
        if (length + size > out.len) return null;
        decoder.decode(out[length..][0..size], &quad) catch return null;
        length += size;
        if (size < 3) break;
    }
    if (filled != 0 or length == 0) return null;
    return out[0..length];
}

test "challenges name their scheme and realm" {
    var parsed: Parsed = .{ .scheme = "", .realm = "" };
    parseChallenge("Basic realm=\"intranet\", charset=\"UTF-8\"", &parsed);
    try std.testing.expectEqualStrings("Basic", parsed.scheme);
    try std.testing.expectEqualStrings("intranet", parsed.realm);
    parseChallenge("Digest qop=\"auth\", realm=\"a \\\"b\\\"\", nonce=x", &parsed);
    try std.testing.expectEqualStrings("a \"b\"", parsed.realm);
    parseChallenge("  NTLM ", &parsed);
    try std.testing.expectEqualStrings("NTLM", parsed.scheme);
    try std.testing.expectEqualStrings("", parsed.realm);
    parseChallenge("Basic realm=plain", &parsed);
    try std.testing.expectEqualStrings("plain", parsed.realm);
    try std.testing.expectEqual(Scheme.ntlm, schemeNamed("NTLM").?);
    try std.testing.expect(schemeNamed("Bearer") == null);
    try std.testing.expectEqual(Scheme.basic, webkitScheme(1).?);
    try std.testing.expect(webkitScheme(7) == null);
}

test "authorities take the scheme's port by default" {
    try std.testing.expectEqual(@as(u16, 443), authority("https://example.test/a").?.port);
    try std.testing.expectEqualStrings("example.test", authority("https://user@example.test:8443/a?b").?.host);
    try std.testing.expectEqual(@as(u16, 8443), authority("https://example.test:8443#x").?.port);
    try std.testing.expectEqualStrings("::1", authority("http://[::1]:81/").?.host);
    try std.testing.expectEqual(@as(u16, 80), authority("http://[::1]").?.port);
    try std.testing.expect(authority("file:///a") == null);
    try std.testing.expect(authority("https://:1/") == null);
    try std.testing.expect(authority("https://a:99999/") == null);
}

test "certificates decode from PEM and errors are worded" {
    var out: [16]u8 = undefined;
    const der = pemCertificate("-----BEGIN CERTIFICATE-----\r\nAQID\r\nBA==\r\n-----END CERTIFICATE-----\r\n", &out).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, der);
    try std.testing.expect(pemCertificate("AQID", &out) == null);
    var small: [2]u8 = undefined;
    try std.testing.expect(pemCertificate("-----BEGIN CERTIFICATE-----AQID-----END CERTIFICATE-----", &small) == null);
    try std.testing.expectEqualStrings("the certificate expired", gtlsReason(1 << 3));
    try std.testing.expectEqualStrings("the certificate's issuer is not known", gtlsReason(1 | 2));
    try std.testing.expectEqualStrings("the certificate was revoked", webview2Reason(4));
}
