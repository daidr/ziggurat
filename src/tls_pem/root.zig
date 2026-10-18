//! Bounded PEM framing only. Native cryptographic parsing remains fallible.
const std = @import("std");

pub const certificate_capacity = 16 * 1024;
pub const private_key_capacity = 16 * 1024;

/// Exactly one public certificate, without keys, chains or ignored trailing
/// material. Shared by explicit Profile trust and owned HTTPS transport.
pub fn validateCertificate(pem: []const u8) !void {
    if (pem.len == 0 or pem.len > certificate_capacity) return error.TlsCertificateCapacityExceeded;
    validateBlock(pem, "CERTIFICATE") catch return error.InvalidTlsCertificate;
}

/// First transport slice accepts one unencrypted PKCS#8 private key. Native
/// cryptographic parsing is separate; a handshake checks deployment. Never log.
pub fn validatePrivateKey(pem: []const u8) !void {
    if (pem.len == 0 or pem.len > private_key_capacity) return error.TlsPrivateKeyCapacityExceeded;
    validateBlock(pem, "PRIVATE KEY") catch return error.InvalidTlsPrivateKey;
}

fn validateBlock(pem: []const u8, comptime label: []const u8) !void {
    const begin = "-----BEGIN " ++ label ++ "-----";
    const end = "-----END " ++ label ++ "-----";
    if (!std.mem.startsWith(u8, pem, begin)) return error.InvalidPem;
    const tail = std.mem.indexOf(u8, pem[begin.len..], end) orelse return error.InvalidPem;
    const body = pem[begin.len..][0..tail];
    var count: usize = 0;
    var padding: usize = 0;
    for (body, 0..) |byte, i| {
        if (byte == '\n') continue;
        if (byte == '\r') {
            if (i + 1 == body.len or body[i + 1] != '\n') return error.InvalidPem;
            continue;
        }
        if (byte == '=') {
            padding += 1;
            if (padding > 2) return error.InvalidPem;
        } else if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/') return error.InvalidPem else if (padding != 0) return error.InvalidPem;
        count += 1;
    }
    if (body.len == 0 or body[0] != '\n' and body[0] != '\r' or count == 0 or count % 4 != 0) return error.InvalidPem;
    const rest = pem[begin.len + tail + end.len ..];
    for (rest, 0..) |byte, i| {
        if (byte == '\n') continue;
        if (byte != '\r' or i + 1 == rest.len or rest[i + 1] != '\n') return error.InvalidPem;
    }
}

test "certificate and private key share bounded exact block framing" {
    const cert = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n";
    const key = "-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----\n";
    try validateCertificate(cert);
    try validatePrivateKey(key);
    try std.testing.expectError(error.InvalidTlsCertificate, validateCertificate(key));
    try std.testing.expectError(error.InvalidTlsPrivateKey, validatePrivateKey(cert));
    inline for (.{ "", "junk", "\x00", "-----BEGIN PRIVATE KEY-----\nYQ==Z\n-----END PRIVATE KEY-----", key ++ key, key ++ "junk", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nYWJj\n-----END ENCRYPTED PRIVATE KEY-----" }) |invalid| {
        if (invalid.len == 0) {
            try std.testing.expectError(error.TlsPrivateKeyCapacityExceeded, validatePrivateKey(invalid));
        } else try std.testing.expectError(error.InvalidTlsPrivateKey, validatePrivateKey(invalid));
    }
    try validatePrivateKey("-----BEGIN PRIVATE KEY-----\r\nYQ==\r\n-----END PRIVATE KEY-----\r\n");
    const excessive = [_]u8{'x'} ** (private_key_capacity + 1);
    try std.testing.expectError(error.TlsPrivateKeyCapacityExceeded, validatePrivateKey(&excessive));
}
