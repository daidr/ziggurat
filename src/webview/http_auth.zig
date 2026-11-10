//! HTTP sign-in, client certificates and server certificate errors of a
//! View's pages (Options.http_auth, Options.client_certificates,
//! Options.certificate_errors): what the engines tell, in the words the app
//! reads.
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

/// One of the certificates a server that asks for one can be given
/// (ClientCertificateRequest.certificates).
pub const ClientCertificate = struct {
    /// The certificate, DER-encoded.
    certificate: []const u8,
    /// Its subject and issuer as the platform names them; on macOS the
    /// subject is the identity's common name and the issuer is read from
    /// the certificate (its common name, else its organization).
    subject: []const u8,
    issuer: []const u8,
    /// The unix seconds it is valid from and to.
    valid_from: i64,
    valid_to: i64,
};

/// A server, or a proxy, asks for the certificate of a TLS connection
/// (mutual TLS) before it serves the page or something the page loads.
pub const ClientCertificateRequest = struct {
    /// The server's host and port, or the proxy's.
    host: []const u8,
    port: u16,
    /// A proxy asks rather than the server.
    proxy: bool,
    /// Those the platform can offer, one of which an answer names by its
    /// index: WebView2's mutually trusted certificates on Windows, the
    /// keychain's identities on macOS. WebKitGTK lists none, so this is
    /// empty on Linux and an answer there can only refuse. Borrowed until
    /// the handler returns.
    certificates: []const ClientCertificate,
};

pub const limits = struct {
    /// Longer credentials are refused, and the sign-in canceled.
    pub const credential_bytes = 1024;
    pub const certificate_bytes = 65536;
    /// More offered client certificates are left out of the request, and
    /// subjects and issuers longer than name_bytes are cut.
    pub const client_certificates = 32;
    pub const name_bytes = 512;
};

/// A certificate as a backend offers it: the DER, and the subject, issuer
/// and validity where the platform names them. A null issuer is read from
/// the DER, validity included.
pub const NativeClientCertificate = extern struct {
    der: ?[*]const u8,
    der_length: usize,
    subject: ?[*:0]const u8,
    issuer: ?[*:0]const u8,
    valid_from: i64,
    valid_to: i64,
};

/// A backend's client certificate challenge: host, port, whether a proxy
/// asks, and the certificates it offers; it returns the index of the one to
/// give, or -1 to refuse.
pub const ClientCertificateOffer = *const fn (*anyopaque, [*:0]const u8, u32, c_int, ?[*]const NativeClientCertificate, u32) callconv(.c) i32;

/// The certificates of a ClientCertificateRequest, built from what a
/// backend offers without allocating, and the backend's index of each.
pub const ClientCertificates = struct {
    items: [limits.client_certificates]ClientCertificate = undefined,
    native_index: [limits.client_certificates]u32 = undefined,
    subjects: [limits.client_certificates][limits.name_bytes]u8 = undefined,
    issuers: [limits.client_certificates][limits.name_bytes]u8 = undefined,
    count: usize = 0,

    /// Certificates without DER, or with DER that is no certificate when
    /// the issuer must be read from it, are left out.
    pub fn fill(self: *ClientCertificates, offered: []const NativeClientCertificate) void {
        self.count = 0;
        for (offered, 0..) |native, i| {
            if (self.count == limits.client_certificates) break;
            const der_pointer = native.der orelse continue;
            if (native.der_length == 0 or native.der_length > limits.certificate_bytes) continue;
            const der = der_pointer[0..native.der_length];
            const slot = self.count;
            var item: ClientCertificate = .{ .certificate = der, .subject = cut(&self.subjects[slot], native.subject), .issuer = "", .valid_from = native.valid_from, .valid_to = native.valid_to };
            if (native.issuer) |issuer| {
                item.issuer = cut(&self.issuers[slot], issuer);
            } else {
                const info = certificateIssuer(der, &self.issuers[slot]) orelse continue;
                item.issuer = info.issuer;
                item.valid_from = info.valid_from;
                item.valid_to = info.valid_to;
            }
            self.items[slot] = item;
            self.native_index[slot] = @intCast(i);
            self.count += 1;
        }
    }
    pub fn slice(self: *const ClientCertificates) []const ClientCertificate {
        return self.items[0..self.count];
    }
    /// The backend's index of the certificate an answer chose, -1 to
    /// refuse: no choice, or an index the request did not offer.
    pub fn answer(self: *const ClientCertificates, choice: ?usize) i32 {
        const index = choice orelse return -1;
        if (index >= self.count) return -1;
        return @intCast(self.native_index[index]);
    }
    fn cut(out: *[limits.name_bytes]u8, text: ?[*:0]const u8) []const u8 {
        const value = std.mem.span(text orelse return "");
        var length = @min(value.len, out.len);
        // Never end inside a UTF-8 sequence.
        if (length < value.len) {
            while (length > 0 and value[length] & 0xc0 == 0x80) length -= 1;
        }
        @memcpy(out[0..length], value[0..length]);
        return out[0..length];
    }
};

pub const CertificateIssuer = struct { issuer: []const u8, valid_from: i64, valid_to: i64 };

/// The issuer's name and the validity of a DER-encoded certificate, for a
/// platform that does not name them: the issuer's common name, or its
/// organization when it has none, written to out (cut to fit), and the
/// unix seconds it is valid from and to. null when der is not a
/// certificate. It walks the few fields it needs, nothing else.
pub fn certificateIssuer(der: []const u8, out: []u8) ?CertificateIssuer {
    const certificate = derField(der, 0x30) orelse return null;
    var tbs = derField(certificate, 0x30) orelse return null;
    if (tbs.len != 0 and tbs[0] == 0xa0) tbs = (derRead(tbs) orelse return null).rest; // [0] version, absent in v1
    // The serial number, the signature's algorithm, the issuer and the
    // validity, in that order.
    var fields: [4][]const u8 = undefined;
    for ([_]u8{ 0x02, 0x30, 0x30, 0x30 }, 0..) |tag, i| {
        const element = derRead(tbs) orelse return null;
        if (element.tag != tag) return null;
        fields[i] = element.content;
        tbs = element.rest;
    }
    var validity = fields[3];
    const from = derTime(&validity) orelse return null;
    const to = derTime(&validity) orelse return null;
    return .{ .issuer = nameIssuer(fields[2], out), .valid_from = from, .valid_to = to };
}

const DerElement = struct { tag: u8, content: []const u8, rest: []const u8 };

/// The DER element at the start of b: its tag, its content and what
/// follows it.
fn derRead(b: []const u8) ?DerElement {
    if (b.len < 2 or b[0] & 0x1f == 0x1f) return null; // no high tag numbers in a certificate's fields
    var length: usize = b[1];
    var rest = b[2..];
    if (length & 0x80 != 0) {
        const size = length & 0x7f;
        if (size == 0 or size > 4 or rest.len < size) return null;
        length = 0;
        for (rest[0..size]) |byte| length = length << 8 | byte;
        rest = rest[size..];
    }
    if (length > rest.len) return null;
    return .{ .tag = b[0], .content = rest[0..length], .rest = rest[length..] };
}

fn derField(b: []const u8, tag: u8) ?[]const u8 {
    const element = derRead(b) orelse return null;
    return if (element.tag == tag) element.content else null;
}

/// The common name of an X.501 name's content, else its organization.
fn nameIssuer(name: []const u8, out: []u8) []const u8 {
    var common: ?[]const u8 = null;
    var organization: ?[]const u8 = null;
    var common_storage: [limits.name_bytes]u8 = undefined;
    var organization_storage: [limits.name_bytes]u8 = undefined;
    var rest = name;
    outer: while (rest.len != 0) {
        const set = derRead(rest) orelse break;
        if (set.tag != 0x31) break;
        rest = set.rest;
        var attributes = set.content;
        while (attributes.len != 0) {
            const attribute = derRead(attributes) orelse continue :outer;
            if (attribute.tag != 0x30) continue :outer;
            attributes = attribute.rest;
            const oid = derRead(attribute.content) orelse continue;
            if (oid.tag != 0x06 or oid.content.len != 3 or oid.content[0] != 0x55 or oid.content[1] != 0x04) continue;
            switch (oid.content[2]) {
                0x03 => if (common == null) {
                    common = derString(oid.rest, &common_storage);
                },
                0x0a => if (organization == null) {
                    organization = derString(oid.rest, &organization_storage);
                },
                else => {},
            }
        }
    }
    const chosen = common orelse organization orelse return "";
    const length = @min(chosen.len, out.len);
    @memcpy(out[0..length], chosen[0..length]);
    return out[0..length];
}

/// A directory string, the value of a name's attribute, as UTF-8.
fn derString(b: []const u8, out: []u8) ?[]const u8 {
    const element = derRead(b) orelse return null;
    switch (element.tag) {
        0x0c, 0x13, 0x14, 0x16 => { // UTF8String, PrintableString, T61String, IA5String
            const length = @min(element.content.len, out.len);
            @memcpy(out[0..length], element.content[0..length]);
            return out[0..length];
        },
        0x1e => { // BMPString, UTF-16BE
            if (element.content.len % 2 != 0) return null;
            var length: usize = 0;
            var i: usize = 0;
            while (i < element.content.len) : (i += 2) {
                const unit = @as(u21, element.content[i]) << 8 | element.content[i + 1];
                var encoded: [4]u8 = undefined;
                const size = std.unicode.utf8Encode(if (unit >= 0xd800 and unit <= 0xdfff) 0xfffd else unit, &encoded) catch return null;
                if (length + size > out.len) break;
                @memcpy(out[length..][0..size], encoded[0..size]);
                length += size;
            }
            return out[0..length];
        },
        else => return null,
    }
}

/// The UTCTime or GeneralizedTime at the start of b.*, in unix seconds;
/// b moves past it.
fn derTime(b: *[]const u8) ?i64 {
    const element = derRead(b.*) orelse return null;
    b.* = element.rest;
    const text = element.content;
    var year: i64 = undefined;
    var digits: []const u8 = undefined;
    switch (element.tag) {
        0x17 => { // UTCTime, YYMMDDHHMMSSZ: years from 50 are the 1900s
            if (text.len != 13) return null;
            const yy = decimal(text[0..2]) orelse return null;
            year = if (yy >= 50) 1900 + yy else 2000 + yy;
            digits = text[2..];
        },
        0x18 => { // GeneralizedTime, YYYYMMDDHHMMSSZ
            if (text.len != 15) return null;
            year = decimal(text[0..4]) orelse return null;
            digits = text[4..];
        },
        else => return null,
    }
    if (digits[10] != 'Z') return null;
    const month = decimal(digits[0..2]) orelse return null;
    const day = decimal(digits[2..4]) orelse return null;
    const hour = decimal(digits[4..6]) orelse return null;
    const minute = decimal(digits[6..8]) orelse return null;
    const second = decimal(digits[8..10]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

fn decimal(text: []const u8) ?i64 {
    var value: i64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// Days from 1970-01-01 to a proleptic Gregorian date.
fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const day_of_year = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// The scheme of an engine's name for it, null for one apps cannot answer
/// with a password (client certificates, which Options.client_certificates
/// answers, and server trust).
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

test "certificates name their issuer and validity" {
    const cases = [_]struct { base64: []const u8, issuer: []const u8, from: i64, to: i64 }{
        // Issuer CN and O, UTCTime.
        .{ .base64 = "MIIBQTCB6aADAgECAgMS1ocwCgYIKoZIzj0EAwIwNTEgMB4GA1UEAwwXemlnZ3VyYXQgdGVzdCBjbGllbnQgQ0ExETAPBgNVBAoMCFppZ2d1cmF0MB4XDTI2MTExMDA4MDAwMFoXDTI3MTExMDA4MDAwMFowHzEdMBsGA1UEAwwUemlnZ3VyYXQgdGVzdCBjbGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQYWcLXWRKE1KQWP6uUwMno3X9Jkazgs7nuEFFzkm335nRp5AhQGE9MeOTBzxm3MVx7OU7370ZmE19NzCn2BMyJMAoGCCqGSM49BAMCA0cAMEQCIEl+rnXCyX3Umix8KD73OV7dIv+1xoQi6gRsXisSV/1xAiBjCl1vlTpdruFlRzX4udPY7BGCdyxFk7bzIJmXv7oN3g==", .issuer = "ziggurat test client CA", .from = 1794297600, .to = 1825833600 },
        // Only an organization; UTCTime years before and after 2000.
        .{ .base64 = "MIIBLjCB1KADAgECAgMS1ocwCgYIKoZIzj0EAwIwIDERMA8GA1UECgwIWmlnZ3VyYXQxCzAJBgNVBAYTAlVTMB4XDTk5MDEwMjAzMDQwNVoXDTQ5MTIzMTIzNTk1OVowHzEdMBsGA1UEAwwUemlnZ3VyYXQgdGVzdCBjbGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQYWcLXWRKE1KQWP6uUwMno3X9Jkazgs7nuEFFzkm335nRp5AhQGE9MeOTBzxm3MVx7OU7370ZmE19NzCn2BMyJMAoGCCqGSM49BAMCA0kAMEYCIQCQdJ2oBiI1z5oFJTnPyW61t5kiBEvcoeTNONTQRmjhXwIhAJbGw3MUT8YeLhAHEMcX6IPFWcifd7ZF5g6G/kAkcN3d", .issuer = "Ziggurat", .from = 915246245, .to = 2524607999 },
        // Years from 2050 are GeneralizedTime; a UTF-8 name.
        .{ .base64 = "MIIBIjCByqADAgECAgMS1ocwCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJ6ZW/5pyfIENBMCAXDTIwMDEwMTAwMDAwMFoYDzIxMDAwMTAxMDAwMDAwWjAfMR0wGwYDVQQDDBR6aWdndXJhdCB0ZXN0IGNsaWVudDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBhZwtdZEoTUpBY/q5TAyejdf0mRrOCzue4QUXOSbffmdGnkCFAYT0x45MHPGbcxXHs5TvfvRmYTX03MKfYEzIkwCgYIKoZIzj0EAwIDRwAwRAIgaGyiyxuqIVr1TCfx+opJsqOnyMrrYGLp6EgMI5dkJBICIB29WW9bj1qq2PiYvfAkqrfA2duLiUDPQ6XzXU7YVSD2", .issuer = "\u{957f}\u{671f} CA", .from = 1577836800, .to = 4102444800 },
    };
    for (cases) |case| {
        var der_storage: [512]u8 = undefined;
        const decoder = std.base64.standard.Decoder;
        const size = try decoder.calcSizeForSlice(case.base64);
        try decoder.decode(der_storage[0..size], case.base64);
        const der = der_storage[0..size];
        var out: [limits.name_bytes]u8 = undefined;
        const info = certificateIssuer(der, &out).?;
        try std.testing.expectEqualStrings(case.issuer, info.issuer);
        try std.testing.expectEqual(case.from, info.valid_from);
        try std.testing.expectEqual(case.to, info.valid_to);
        for (0..der.len) |n| try std.testing.expect(certificateIssuer(der[0..n], &out) == null);
    }
    var out: [8]u8 = undefined;
    try std.testing.expect(certificateIssuer("", &out) == null);
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
}

test "client certificates are offered and answered by index" {
    const der = [_]u8{ 0x30, 0x82, 0x01, 0x0a };
    const other = [_]u8{ 0x30, 0x00 };
    const offered = [_]NativeClientCertificate{
        .{ .der = null, .der_length = 0, .subject = "CN=none", .issuer = "", .valid_from = 0, .valid_to = 0 },
        .{ .der = &der, .der_length = der.len, .subject = "CN=me", .issuer = "CN=ziggurat e2e CA", .valid_from = 1760000000, .valid_to = 1790000000 },
        // No issuer named, and DER that is no certificate: left out.
        .{ .der = &other, .der_length = other.len, .subject = "CN=broken", .issuer = null, .valid_from = 0, .valid_to = 0 },
        .{ .der = &other, .der_length = other.len, .subject = null, .issuer = "CN=ziggurat e2e CA", .valid_from = 1, .valid_to = 2 },
    };
    var list: ClientCertificates = .{};
    list.fill(&offered);
    const items = list.slice();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("CN=me", items[0].subject);
    try std.testing.expectEqualStrings("CN=ziggurat e2e CA", items[0].issuer);
    try std.testing.expectEqualSlices(u8, &der, items[0].certificate);
    try std.testing.expectEqual(@as(i64, 1760000000), items[0].valid_from);
    try std.testing.expectEqual(@as(i64, 1790000000), items[0].valid_to);
    try std.testing.expectEqualStrings("", items[1].subject);
    // Answers name the backend's own certificate; anything else refuses.
    try std.testing.expectEqual(@as(i32, 1), list.answer(0));
    try std.testing.expectEqual(@as(i32, 3), list.answer(1));
    try std.testing.expectEqual(@as(i32, -1), list.answer(2));
    try std.testing.expectEqual(@as(i32, -1), list.answer(null));
    list.fill(&.{});
    try std.testing.expectEqual(@as(usize, 0), list.slice().len);
    try std.testing.expectEqual(@as(i32, -1), list.answer(0));
}

test "long names are cut on a character boundary" {
    var long: [limits.name_bytes + 2:0]u8 = undefined;
    @memset(long[0 .. limits.name_bytes - 1], 'a');
    @memcpy(long[limits.name_bytes - 1 ..][0..3], "\u{957f}");
    const der = [_]u8{ 0x30, 0x00 };
    var list: ClientCertificates = .{};
    list.fill(&.{.{ .der = &der, .der_length = der.len, .subject = &long, .issuer = "", .valid_from = 0, .valid_to = 0 }});
    try std.testing.expectEqual(@as(usize, limits.name_bytes - 1), list.slice()[0].subject.len);
}
