//! Explicit creation-time trust for a host-owned loopback HTTPS service.
const std = @import("std");
const pem_format = @import("ziggurat_tls_pem");

pub const host = "127.0.0.1";
pub const max_pem_bytes = pem_format.certificate_capacity;

/// This authorizes certificate errors for this one leaf certificate and host
/// throughout the Profile's native manager. It is not mandatory pinning or a
/// port boundary. The server, its private key and its lifetime belong to host.
pub const LoopbackHttps = struct { certificate_pem: []const u8 };

/// Stack-owned across the constructor's first caller allocator and every
/// foreign cleanup. Only the opt-in noinline constructor creates this frame.
pub const Captured = struct {
    bytes: [max_pem_bytes + 1]u8 = undefined,
    len: usize,

    pub fn capture(input: LoopbackHttps) !Captured {
        var result: Captured = undefined;
        try result.captureInto(input);
        return result;
    }
    /// Production constructors provide one stable output object; no large
    /// by-value return or implicit copy is required for the stack capture.
    pub fn captureInto(self: *Captured, input: LoopbackHttps) !void {
        if (input.certificate_pem.len == 0 or input.certificate_pem.len > max_pem_bytes) return error.TlsCertificateCapacityExceeded;
        self.len = input.certificate_pem.len;
        @memcpy(self.bytes[0..self.len], input.certificate_pem);
        self.bytes[self.len] = 0;
        try validate(self.bytes[0..self.len]);
    }
    pub fn pem(self: *const Captured) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};

/// One certificate block only; native X.509 parsing is a separate fallible
/// constructor step. No keys, concatenated chains or ignored trailing data.
pub fn validate(bytes: []const u8) !void {
    return pem_format.validateCertificate(bytes);
}

test "TLS policy captures before caller storage changes and requires one public certificate" {
    var input = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n".*;
    const copy = try Captured.capture(.{ .certificate_pem = &input });
    @memset(&input, 0);
    try std.testing.expectEqualStrings("-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n", copy.pem());
    try validate("-----BEGIN CERTIFICATE-----\r\nYQ==\r\n-----END CERTIFICATE-----\r\n");
    inline for (.{ "-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----", "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----junk", "-----BEGIN CERTIFICATE-----\nYQ==Z\n-----END CERTIFICATE-----", "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----", "-----BEGIN CERTIFICATE-----\nY\x00Jj\n-----END CERTIFICATE-----", "-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----" }) |invalid| {
        try std.testing.expectError(error.InvalidTlsCertificate, validate(invalid));
    }
    try std.testing.expectError(error.TlsCertificateCapacityExceeded, Captured.capture(.{ .certificate_pem = "" }));
    const oversized: [max_pem_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.TlsCertificateCapacityExceeded, Captured.capture(.{ .certificate_pem = &oversized }));
}
