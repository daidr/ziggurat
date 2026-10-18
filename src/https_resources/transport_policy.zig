const std = @import("std");
const pem = @import("ziggurat_tls_pem");

pub const certificate_capacity = pem.certificate_capacity;
pub const private_key_capacity = pem.private_key_capacity;
pub const Material = struct { certificate_pem: []const u8, private_key_pem: []const u8 };

/// One opt-in stable constructor frame. All caller bytes are owned before
/// validation/foreign entry; every exit wipes the entire combined key storage.
pub const Captured = struct {
    bytes: [certificate_capacity + private_key_capacity + 2]u8 = undefined,
    length: usize = 0,
    certificate_length: usize = 0,

    pub fn init(self: *Captured, input: Material) !void {
        if (input.certificate_pem.len == 0 or input.certificate_pem.len > certificate_capacity) return error.TlsCertificateCapacityExceeded;
        if (input.private_key_pem.len == 0 or input.private_key_pem.len > private_key_capacity) return error.TlsPrivateKeyCapacityExceeded;
        self.length = input.certificate_pem.len + 1 + input.private_key_pem.len;
        self.certificate_length = input.certificate_pem.len;
        @memcpy(self.bytes[0..input.certificate_pem.len], input.certificate_pem);
        self.bytes[input.certificate_pem.len] = '\n';
        @memcpy(self.bytes[input.certificate_pem.len + 1 .. self.length], input.private_key_pem);
        self.bytes[self.length] = 0;
        try pem.validateCertificate(self.bytes[0..self.certificate_length]);
        try pem.validatePrivateKey(self.bytes[self.certificate_length + 1 .. self.length]);
    }
    pub fn deinit(self: *Captured) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.length = 0;
        self.certificate_length = 0;
    }
};

test "transport capture owns both PEM inputs and wipes even partially validated material" {
    var cert = "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----\n".*;
    var key = "-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----\n".*;
    var capture: Captured = undefined;
    try capture.init(.{ .certificate_pem = &cert, .private_key_pem = &key });
    @memset(&cert, 'x');
    @memset(&key, 'x');
    try std.testing.expect(std.mem.indexOf(u8, capture.bytes[0..capture.length], "YWJj") != null);
    capture.deinit();
    try std.testing.expectEqual(@as(usize, 0), capture.length);
    try std.testing.expect(std.mem.allEqual(u8, &capture.bytes, 0));
    try std.testing.expectError(error.InvalidTlsCertificate, capture.init(.{ .certificate_pem = &cert, .private_key_pem = &key }));
    capture.deinit();
    try std.testing.expect(std.mem.allEqual(u8, &capture.bytes, 0));
}
