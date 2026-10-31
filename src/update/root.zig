const std = @import("std");
pub const publication = @import("publication.zig");
pub const archive = @import("archive.zig");
pub const delta = @import("delta.zig");
pub const feed = @import("feed.zig");
pub const download = @import("download.zig");
pub const retention = @import("retention.zig");
pub const launch = @import("launch.zig");
pub const http = @import("http.zig");
test {
    _ = publication;
    _ = archive;
    _ = delta;
    _ = feed;
    _ = download;
    _ = retention;
    _ = launch;
    _ = http;
    _ = @import("publication_test.zig");
    _ = @import("flow_test.zig");
}
pub const Ed25519 = std.crypto.sign.Ed25519;
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
    revision: u16 = 0,
    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch", "revision" }) |field| {
            const result = std.math.order(@field(a, field), @field(b, field));
            if (result != .eq) return result;
        }
        return .eq;
    }
};
pub const Manifest = struct {
    identity: []const u8,
    version: Version,
    target: []const u8,
    url: []const u8,
    bytes: u64,
    sha256: [32]u8,
    signature: [64]u8,
    /// Present while a release is signed by a rotated key: the trusted key
    /// endorses the new signing key for this identity.
    endorsement: ?Endorsement = null,
};
/// A trusted key's statement that `public_key` may sign releases of one identity.
pub const Endorsement = struct { public_key: [32]u8, signature: [64]u8 };
pub const Policy = struct {
    identity: []const u8,
    target: []const u8,
    current_version: Version,
    public_key: [32]u8,
    /// Keys accepted alongside `public_key`, for example during a rotation.
    additional_public_keys: []const [32]u8 = &.{},
    max_artifact_bytes: u64 = 256 * 1024 * 1024,
    max_manifest_bytes: usize = 16384,
};
pub const EndorsementWire = struct { public_key: []const u8, signature: []const u8 };
/// JSON form of a signed manifest. Unknown and duplicate fields are rejected.
pub const Wire = struct { format: u16, identity: []const u8, version: Version, target: []const u8, url: []const u8, bytes: u64, sha256: []const u8, signature: []const u8, endorsement: ?EndorsementWire = null };
pub const Verified = struct {
    parsed: std.json.Parsed(Wire),
    manifest: Manifest,
    pub fn deinit(self: Verified) void {
        self.parsed.deinit();
    }
};

fn identifier(text: []const u8) bool {
    if (text.len == 0 or text.len > 128 or !std.ascii.isAlphanumeric(text[0])) return false;
    for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}
fn validate(manifest: Manifest) !void {
    if (!identifier(manifest.identity) or !identifier(manifest.target)) return error.InvalidIdentity;
    if (manifest.bytes == 0) return error.InvalidSize;
    if (manifest.url.len == 0 or manifest.url.len > 2048) return error.InvalidUrl;
    for (manifest.url) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return error.InvalidUrl;
    const uri = std.Uri.parse(manifest.url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidUrl;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidUrl;
    if (host.bytes.len == 0) return error.InvalidUrl;
}

/// Canonical signing payload. Caller storage owns the returned slice.
/// Strings cannot contain separators; numbers and digest use one representation.
pub fn signingPayload(manifest: Manifest, buffer: []u8) ![]const u8 {
    try validate(manifest);
    const digest = std.fmt.bytesToHex(manifest.sha256, .lower);
    return std.fmt.bufPrint(buffer, "ziggurat-update-v1\n{s}\n{d}.{d}.{d}.{d}\n{s}\n{s}\n{d}\n{s}\n", .{
        manifest.identity, manifest.version.major, manifest.version.minor, manifest.version.patch, manifest.version.revision,
        manifest.target,   manifest.url,           manifest.bytes,         digest,
    });
}

pub fn verify(manifest: Manifest, policy: Policy) !void {
    try validate(manifest);
    if (!std.mem.eql(u8, policy.identity, manifest.identity)) return error.WrongIdentity;
    if (!std.mem.eql(u8, policy.target, manifest.target)) return error.WrongTarget;
    if (manifest.bytes > policy.max_artifact_bytes) return error.ArtifactTooLarge;
    switch (manifest.version.order(policy.current_version)) {
        .lt => return error.DowngradeRejected,
        .eq => return error.AlreadyCurrent,
        .gt => {},
    }
    var buffer: [4096]u8 = undefined;
    const payload = try signingPayload(manifest, &buffer);
    const signer = try signingKey(manifest.identity, manifest.endorsement, policy);
    const key = Ed25519.PublicKey.fromBytes(signer) catch return error.InvalidPublicKey;
    Ed25519.Signature.fromBytes(manifest.signature).verify(payload, key) catch return error.InvalidSignature;
}

fn trusted(key: [32]u8, policy: Policy) bool {
    if (std.mem.eql(u8, &key, &policy.public_key)) return true;
    for (policy.additional_public_keys) |other| if (std.mem.eql(u8, &key, &other)) return true;
    return false;
}

/// The key that must have signed a manifest or delta: a trusted key, or a key
/// endorsed by a trusted key for this identity. Endorsements do not chain.
pub fn signingKey(identity: []const u8, endorsement: ?Endorsement, policy: Policy) ![32]u8 {
    const statement = endorsement orelse return policy.public_key;
    if (trusted(statement.public_key, policy)) return statement.public_key;
    var buffer: [256]u8 = undefined;
    const payload = try endorsementPayload(identity, statement.public_key, &buffer);
    var keys: [17][32]u8 = undefined;
    if (policy.additional_public_keys.len > 16) return error.TooManyKeys;
    keys[0] = policy.public_key;
    @memcpy(keys[1..][0..policy.additional_public_keys.len], policy.additional_public_keys);
    for (keys[0 .. policy.additional_public_keys.len + 1]) |anchor| {
        const key = Ed25519.PublicKey.fromBytes(anchor) catch continue;
        Ed25519.Signature.fromBytes(statement.signature).verify(payload, key) catch continue;
        return statement.public_key;
    }
    return error.UntrustedSigningKey;
}

pub fn endorsementPayload(identity: []const u8, public_key: [32]u8, buffer: []u8) ![]const u8 {
    if (!identifier(identity)) return error.InvalidIdentity;
    return std.fmt.bufPrint(buffer, "ziggurat-key-v1\n{s}\n{s}\n", .{ identity, std.fmt.bytesToHex(public_key, .lower) });
}

/// Sign `new_key` with the currently trusted key so existing installations
/// accept releases signed by the new key.
pub fn endorse(identity: []const u8, trusted_key: Ed25519.KeyPair, new_key: [32]u8) !Endorsement {
    var buffer: [256]u8 = undefined;
    const signature = try trusted_key.sign(try endorsementPayload(identity, new_key, &buffer), null);
    return .{ .public_key = new_key, .signature = signature.toBytes() };
}

pub fn decodeEndorsement(wire: ?EndorsementWire) !?Endorsement {
    const value = wire orelse return null;
    if (value.public_key.len != 64 or value.signature.len != 128) return error.InvalidEncoding;
    var result: Endorsement = undefined;
    _ = std.fmt.hexToBytes(&result.public_key, value.public_key) catch return error.InvalidEncoding;
    _ = std.fmt.hexToBytes(&result.signature, value.signature) catch return error.InvalidEncoding;
    return result;
}

pub const EndorsementHex = struct {
    public_key: [64]u8,
    signature: [128]u8,
    pub fn init(value: Endorsement) EndorsementHex {
        return .{ .public_key = std.fmt.bytesToHex(value.public_key, .lower), .signature = std.fmt.bytesToHex(value.signature, .lower) };
    }
    pub fn wire(self: *const EndorsementHex) EndorsementWire {
        return .{ .public_key = &self.public_key, .signature = &self.signature };
    }
};

/// Owns all parsed strings. Unknown/duplicate fields and non-HTTPS URLs fail closed.
pub fn parseAndVerify(allocator: std.mem.Allocator, bytes: []const u8, policy: Policy) !Verified {
    if (bytes.len > policy.max_manifest_bytes) return error.ManifestTooLarge;
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidManifest;
    };
    errdefer parsed.deinit();
    const wire = parsed.value;
    if (wire.format != 1) return error.UnsupportedFormat;
    if (wire.sha256.len != 64 or wire.signature.len != 128) return error.InvalidEncoding;
    var manifest: Manifest = .{
        .identity = wire.identity,
        .version = wire.version,
        .target = wire.target,
        .url = wire.url,
        .bytes = wire.bytes,
        .sha256 = undefined,
        .signature = undefined,
        .endorsement = try decodeEndorsement(wire.endorsement),
    };
    _ = std.fmt.hexToBytes(&manifest.sha256, wire.sha256) catch return error.InvalidEncoding;
    _ = std.fmt.hexToBytes(&manifest.signature, wire.signature) catch return error.InvalidEncoding;
    try verify(manifest, policy);
    return .{ .parsed = parsed, .manifest = manifest };
}

/// Produce signed metadata with an explicitly provided key; no key is persisted.
pub fn sign(allocator: std.mem.Allocator, source: Manifest, key: Ed25519.KeyPair) ![]u8 {
    var buffer: [4096]u8 = undefined;
    const signature = try key.sign(try signingPayload(source, &buffer), null);
    const digest_hex = std.fmt.bytesToHex(source.sha256, .lower);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    var endorsement: EndorsementHex = undefined;
    if (source.endorsement) |value| endorsement = .init(value);
    return std.json.Stringify.valueAlloc(allocator, Wire{
        .format = 1,
        .identity = source.identity,
        .version = source.version,
        .target = source.target,
        .url = source.url,
        .bytes = source.bytes,
        .sha256 = &digest_hex,
        .signature = &signature_hex,
        .endorsement = if (source.endorsement != null) endorsement.wire() else null,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

pub const Receipt = struct { bytes: u64, sha256: [32]u8 };
/// Copy only to caller-owned staging storage. Installation is a separate step.
/// A failed transfer leaves an unverified stage, which the caller must discard.
pub fn stage(manifest: Manifest, reader: *std.Io.Reader, writer: *std.Io.Writer) !Receipt {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var count: u64 = 0;
    while (true) {
        const size = try reader.readSliceShort(&buffer);
        if (size == 0) break;
        if (size > manifest.bytes - count) return error.SizeMismatch;
        hasher.update(buffer[0..size]);
        try writer.writeAll(buffer[0..size]);
        count += size;
    }
    if (count != manifest.bytes) return error.SizeMismatch;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, manifest.sha256)) return error.HashMismatch;
    return .{ .bytes = count, .sha256 = digest };
}

test "signed manifest binds identity target version URL size and artifact digest" {
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(73));
    var manifest: Manifest = .{
        .identity = "org.ziggurat.Test",
        .target = "windows-x86_64",
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
        .url = "https://updates.example.invalid/app.zip",
        .bytes = 3,
        .sha256 = undefined,
        .signature = undefined,
    };
    std.crypto.hash.sha2.Sha256.hash("abc", &manifest.sha256, .{});
    const json = try sign(std.testing.allocator, manifest, key);
    defer std.testing.allocator.free(json);
    const policy: Policy = .{ .identity = manifest.identity, .target = manifest.target, .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() };
    const verified = try parseAndVerify(std.testing.allocator, json, policy);
    defer verified.deinit();
    manifest = verified.manifest;
    var changed = manifest;
    changed.url = "https://updates.example.invalid/other.zip";
    try std.testing.expectError(error.InvalidSignature, verify(changed, policy));
    changed = manifest;
    changed.sha256[0] ^= 1;
    try std.testing.expectError(error.InvalidSignature, verify(changed, policy));
    changed = manifest;
    changed.identity = "other";
    try std.testing.expectError(error.WrongIdentity, verify(changed, policy));
    changed = manifest;
    changed.target = "linux-x86_64";
    try std.testing.expectError(error.WrongTarget, verify(changed, policy));
    changed = manifest;
    changed.version = policy.current_version;
    try std.testing.expectError(error.AlreadyCurrent, verify(changed, policy));
    changed.version.patch = 0;
    changed.version.major = 0;
    try std.testing.expectError(error.DowngradeRejected, verify(changed, policy));
    changed = manifest;
    changed.url = "http://updates.example.invalid/app.zip";
    try std.testing.expectError(error.InvalidUrl, verify(changed, policy));
    changed = manifest;
    changed.url = "https://user@updates.example.invalid/app.zip";
    try std.testing.expectError(error.InvalidUrl, verify(changed, policy));
    var bad_policy = policy;
    bad_policy.max_artifact_bytes = 2;
    try std.testing.expectError(error.ArtifactTooLarge, verify(manifest, bad_policy));
    bad_policy = policy;
    bad_policy.max_manifest_bytes = json.len - 1;
    try std.testing.expectError(error.ManifestTooLarge, parseAndVerify(std.testing.allocator, json, bad_policy));
    var reader: std.Io.Reader = .fixed("abc");
    var destination: [3]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&destination);
    const receipt = try stage(manifest, &reader, &writer);
    try std.testing.expectEqual(3, receipt.bytes);
    try std.testing.expectEqualStrings("abc", &destination);
    reader = .fixed("abcd");
    writer = .fixed(&destination);
    try std.testing.expectError(error.SizeMismatch, stage(manifest, &reader, &writer));
    reader = .fixed("ab");
    writer = .fixed(&destination);
    try std.testing.expectError(error.SizeMismatch, stage(manifest, &reader, &writer));
    reader = .fixed("abd");
    writer = .fixed(&destination);
    try std.testing.expectError(error.HashMismatch, stage(manifest, &reader, &writer));
}

test "signed parsing frees all allocations at every failure" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const key = try Ed25519.KeyPair.generateDeterministic(@splat(19));
            var manifest: Manifest = .{ .identity = "org.ziggurat.Fault", .target = "linux-x86_64", .version = .{ .major = 1, .minor = 0, .patch = 0 }, .url = "https://example.invalid/file", .bytes = 1, .sha256 = undefined, .signature = undefined };
            std.crypto.hash.sha2.Sha256.hash("x", &manifest.sha256, .{});
            const json = try sign(allocator, manifest, key);
            defer allocator.free(json);
            const parsed = try parseAndVerify(allocator, json, .{ .identity = manifest.identity, .target = manifest.target, .current_version = .{ .major = 0, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() });
            defer parsed.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}
