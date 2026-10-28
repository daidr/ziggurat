const std = @import("std");
const zio = @import("ziggurat_io");
const update = @import("root.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Patch format: "ZGDELTA1", source bytes and result bytes as u64 LE, then
/// operations: 1 = copy (u64 source offset, u32 length), 2 = insert (u32
/// length and bytes), 0 = end. A patch only rebuilds bytes; the signed delta
/// manifest binds which source and result those bytes must be.
pub const magic = "ZGDELTA1";
const block = 32;
const max_operation: u32 = 1 << 24;

pub const Limits = struct {
    max_patch_bytes: u64 = 256 * 1024 * 1024,
    max_result_bytes: u64 = 256 * 1024 * 1024,
};

/// Create a patch from `source` to `result`. Both inputs are caller-owned and
/// held in memory; generation belongs to release tooling, not the client.
pub fn diff(allocator: std.mem.Allocator, source: []const u8, result: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll(magic);
    try writer.writeInt(u64, source.len, .little);
    try writer.writeInt(u64, result.len, .little);
    var index: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer index.deinit(allocator);
    if (source.len >= block) {
        try index.ensureTotalCapacity(allocator, @intCast(source.len / block + 1));
        var offset: usize = 0;
        while (offset + block <= source.len) : (offset += block) {
            const entry = index.getOrPutAssumeCapacity(hashBlock(source[offset..][0..block]));
            if (!entry.found_existing) entry.value_ptr.* = offset;
        }
    }
    var pending: usize = 0;
    var position: usize = 0;
    var rolling: u64 = 0;
    var rolling_valid = false;
    while (position + block <= result.len) {
        if (!rolling_valid) {
            rolling = hashBlock(result[position..][0..block]);
            rolling_valid = true;
        }
        if (index.get(rolling)) |start| {
            const candidate: usize = @intCast(start);
            if (std.mem.eql(u8, source[candidate..][0..block], result[position..][0..block])) {
                var source_start = candidate;
                var result_start = position;
                while (source_start > 0 and result_start > pending and source[source_start - 1] == result[result_start - 1]) {
                    source_start -= 1;
                    result_start -= 1;
                }
                var length = position + block - result_start;
                while (source_start + length < source.len and result_start + length < result.len and source[source_start + length] == result[result_start + length]) length += 1;
                try writeInsert(writer, result[pending..result_start]);
                var copied: usize = 0;
                while (copied < length) {
                    const part: u32 = @intCast(@min(length - copied, max_operation));
                    try writer.writeByte(1);
                    try writer.writeInt(u64, source_start + copied, .little);
                    try writer.writeInt(u32, part, .little);
                    copied += part;
                }
                position = result_start + length;
                pending = position;
                rolling_valid = false;
                continue;
            }
        }
        if (position + block < result.len) rolling = roll(rolling, result[position], result[position + block]);
        position += 1;
    }
    try writeInsert(writer, result[pending..]);
    try writer.writeByte(0);
}

const base: u64 = 1099511628211;
const base_power = blk: {
    var value: u64 = 1;
    for (0..block - 1) |_| value *%= base;
    break :blk value;
};
fn hashBlock(bytes: *const [block]u8) u64 {
    var value: u64 = 0;
    for (bytes) |byte| value = value *% base +% (@as(u64, byte) + 1);
    return value;
}
fn roll(value: u64, outgoing: u8, incoming: u8) u64 {
    return (value -% (@as(u64, outgoing) + 1) *% base_power) *% base +% (@as(u64, incoming) + 1);
}

fn writeInsert(writer: *std.Io.Writer, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const part = @min(rest.len, max_operation);
        try writer.writeByte(2);
        try writer.writeInt(u32, @intCast(part), .little);
        try writer.writeAll(rest[0..part]);
        rest = rest[part..];
    }
}

pub const Applied = struct { bytes: u64, sha256: [32]u8 };

/// Rebuild a result from a positional `source` file and a patch stream.
/// Every copy is bounds-checked against the declared source size and the
/// result never exceeds `limits.max_result_bytes`. The caller verifies the
/// returned digest (see `applyVerified`).
pub fn apply(source: std.Io.File, patch: *std.Io.Reader, writer: *std.Io.Writer, limits: Limits) !Applied {
    var header: [magic.len]u8 = undefined;
    patch.readSliceAll(&header) catch return error.InvalidPatch;
    if (!std.mem.eql(u8, &header, magic)) return error.InvalidPatch;
    const source_bytes = patch.takeInt(u64, .little) catch return error.InvalidPatch;
    const result_bytes = patch.takeInt(u64, .little) catch return error.InvalidPatch;
    if (result_bytes > limits.max_result_bytes) return error.ResultTooLarge;
    if ((try source.stat(zio.io())).size != source_bytes) return error.SourceMismatch;
    var hasher: Sha256 = .init(.{});
    var written: u64 = 0;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const tag = patch.takeByte() catch return error.InvalidPatch;
        switch (tag) {
            0 => break,
            1 => {
                const offset = patch.takeInt(u64, .little) catch return error.InvalidPatch;
                const length = patch.takeInt(u32, .little) catch return error.InvalidPatch;
                if (length == 0 or offset > source_bytes or length > source_bytes - offset or length > result_bytes - written) return error.InvalidPatch;
                var done: u64 = 0;
                while (done < length) {
                    const part: usize = @intCast(@min(buffer.len, length - done));
                    const n = try source.readPositionalAll(zio.io(), buffer[0..part], offset + done);
                    if (n != part) return error.SourceMismatch;
                    hasher.update(buffer[0..part]);
                    try writer.writeAll(buffer[0..part]);
                    done += part;
                }
                written += length;
            },
            2 => {
                const length = patch.takeInt(u32, .little) catch return error.InvalidPatch;
                if (length == 0 or length > result_bytes - written) return error.InvalidPatch;
                var done: u64 = 0;
                while (done < length) {
                    const part: usize = @intCast(@min(buffer.len, length - done));
                    patch.readSliceAll(buffer[0..part]) catch return error.InvalidPatch;
                    hasher.update(buffer[0..part]);
                    try writer.writeAll(buffer[0..part]);
                    done += part;
                }
                written += length;
            },
            else => return error.InvalidPatch,
        }
    }
    if (written != result_bytes) return error.InvalidPatch;
    if (patch.takeByte()) |_| return error.InvalidPatch else |err| if (err != error.EndOfStream) return error.InvalidPatch;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .bytes = written, .sha256 = digest };
}

/// Signed description of one patch. It binds the installed source archive
/// (version and digest) to the full result archive, so a client that applies
/// it obtains exactly the bytes a full manifest for `to` describes.
pub const Manifest = struct {
    identity: []const u8,
    target: []const u8,
    from: update.Version,
    to: update.Version,
    source_bytes: u64,
    source_sha256: [32]u8,
    url: []const u8,
    bytes: u64,
    sha256: [32]u8,
    result_bytes: u64,
    result_sha256: [32]u8,
    signature: [64]u8,
    endorsement: ?update.Endorsement = null,

    /// The patch transfer as an ordinary artifact for `update.stage` and
    /// `download.fetch`; it is not itself a release.
    pub fn artifact(self: Manifest) update.Manifest {
        return .{ .identity = self.identity, .target = self.target, .version = self.to, .url = self.url, .bytes = self.bytes, .sha256 = self.sha256, .signature = self.signature, .endorsement = self.endorsement };
    }
};

pub const Wire = struct {
    format: u16,
    kind: []const u8,
    identity: []const u8,
    target: []const u8,
    from: update.Version,
    to: update.Version,
    source_bytes: u64,
    source_sha256: []const u8,
    url: []const u8,
    bytes: u64,
    sha256: []const u8,
    result_bytes: u64,
    result_sha256: []const u8,
    signature: []const u8,
    endorsement: ?update.EndorsementWire = null,
};

pub const Verified = struct {
    parsed: std.json.Parsed(Wire),
    manifest: Manifest,
    pub fn deinit(self: Verified) void {
        self.parsed.deinit();
    }
};

pub fn signingPayload(manifest: Manifest, buffer: []u8) ![]const u8 {
    // Reuse the full-manifest URL, identity and size validation for the patch.
    var scratch: [4096]u8 = undefined;
    _ = try update.signingPayload(manifest.artifact(), &scratch);
    if (manifest.result_bytes == 0 or manifest.source_bytes == 0) return error.InvalidSize;
    const v = manifest.from;
    const w = manifest.to;
    return std.fmt.bufPrint(buffer, "ziggurat-delta-v1\n{s}\n{s}\n{d}.{d}.{d}.{d}\n{d}.{d}.{d}.{d}\n{d}\n{s}\n{s}\n{d}\n{s}\n{d}\n{s}\n", .{
        manifest.identity,                                  manifest.target,
        v.major,                                            v.minor,
        v.patch,                                            v.revision,
        w.major,                                            w.minor,
        w.patch,                                            w.revision,
        manifest.source_bytes,                              std.fmt.bytesToHex(manifest.source_sha256, .lower),
        manifest.url,                                       manifest.bytes,
        std.fmt.bytesToHex(manifest.sha256, .lower),        manifest.result_bytes,
        std.fmt.bytesToHex(manifest.result_sha256, .lower),
    });
}

/// `installed` is the release the client runs and `source_sha256` the digest
/// of its retained archive; a delta for any other source is rejected.
pub fn verify(manifest: Manifest, policy: update.Policy, installed_sha256: [32]u8) !void {
    if (!std.mem.eql(u8, policy.identity, manifest.identity)) return error.WrongIdentity;
    if (!std.mem.eql(u8, policy.target, manifest.target)) return error.WrongTarget;
    if (manifest.from.order(policy.current_version) != .eq) return error.WrongSource;
    if (!std.crypto.timing_safe.eql([32]u8, manifest.source_sha256, installed_sha256)) return error.WrongSource;
    switch (manifest.to.order(manifest.from)) {
        .lt => return error.DowngradeRejected,
        .eq => return error.AlreadyCurrent,
        .gt => {},
    }
    if (manifest.bytes > policy.max_artifact_bytes or manifest.result_bytes > policy.max_artifact_bytes) return error.ArtifactTooLarge;
    var buffer: [4096]u8 = undefined;
    const payload = try signingPayload(manifest, &buffer);
    const signer = try update.signingKey(manifest.identity, manifest.endorsement, policy);
    const key = update.Ed25519.PublicKey.fromBytes(signer) catch return error.InvalidPublicKey;
    update.Ed25519.Signature.fromBytes(manifest.signature).verify(payload, key) catch return error.InvalidSignature;
}

fn hex32(out: *[32]u8, text: []const u8) !void {
    if (text.len != 64) return error.InvalidEncoding;
    _ = std.fmt.hexToBytes(out, text) catch return error.InvalidEncoding;
}

pub fn parseAndVerify(allocator: std.mem.Allocator, bytes: []const u8, policy: update.Policy, installed_sha256: [32]u8) !Verified {
    if (bytes.len > policy.max_manifest_bytes) return error.ManifestTooLarge;
    const parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidManifest;
    };
    errdefer parsed.deinit();
    const wire = parsed.value;
    if (wire.format != 1 or !std.mem.eql(u8, wire.kind, "delta")) return error.UnsupportedFormat;
    if (wire.signature.len != 128) return error.InvalidEncoding;
    var manifest: Manifest = .{
        .identity = wire.identity,
        .target = wire.target,
        .from = wire.from,
        .to = wire.to,
        .source_bytes = wire.source_bytes,
        .source_sha256 = undefined,
        .url = wire.url,
        .bytes = wire.bytes,
        .sha256 = undefined,
        .result_bytes = wire.result_bytes,
        .result_sha256 = undefined,
        .signature = undefined,
        .endorsement = try update.decodeEndorsement(wire.endorsement),
    };
    try hex32(&manifest.source_sha256, wire.source_sha256);
    try hex32(&manifest.sha256, wire.sha256);
    try hex32(&manifest.result_sha256, wire.result_sha256);
    _ = std.fmt.hexToBytes(&manifest.signature, wire.signature) catch return error.InvalidEncoding;
    try verify(manifest, policy, installed_sha256);
    return .{ .parsed = parsed, .manifest = manifest };
}

pub fn sign(allocator: std.mem.Allocator, source: Manifest, key: update.Ed25519.KeyPair) ![]u8 {
    var buffer: [4096]u8 = undefined;
    const signature = try key.sign(try signingPayload(source, &buffer), null);
    const source_hex = std.fmt.bytesToHex(source.source_sha256, .lower);
    const patch_hex = std.fmt.bytesToHex(source.sha256, .lower);
    const result_hex = std.fmt.bytesToHex(source.result_sha256, .lower);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    var endorsement: update.EndorsementHex = undefined;
    if (source.endorsement) |value| endorsement = .init(value);
    return std.json.Stringify.valueAlloc(allocator, Wire{
        .format = 1,
        .kind = "delta",
        .identity = source.identity,
        .target = source.target,
        .from = source.from,
        .to = source.to,
        .source_bytes = source.source_bytes,
        .source_sha256 = &source_hex,
        .url = source.url,
        .bytes = source.bytes,
        .sha256 = &patch_hex,
        .result_bytes = source.result_bytes,
        .result_sha256 = &result_hex,
        .signature = &signature_hex,
        .endorsement = if (source.endorsement != null) endorsement.wire() else null,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

/// Rebuild the full archive into `output` and require the signed result size
/// and digest. `full` must describe the same result; on any error the caller
/// discards `output` and falls back to the full archive.
pub fn applyVerified(verified: *const Verified, full: update.Manifest, source: std.Io.File, patch: std.Io.File, output: *std.Io.Writer, limits: Limits) !void {
    const manifest = verified.manifest;
    if (full.version.order(manifest.to) != .eq or full.bytes != manifest.result_bytes or !std.crypto.timing_safe.eql([32]u8, full.sha256, manifest.result_sha256)) return error.DeltaResultMismatch;
    if ((try patch.stat(zio.io())).size != manifest.bytes or manifest.bytes > limits.max_patch_bytes) return error.SizeMismatch;
    // The patch file was produced by a caller transfer; hash the exact bytes first.
    var check_buffer: [16 * 1024]u8 = undefined;
    var check = patch.reader(zio.io(), &check_buffer);
    var discard_buffer: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);
    _ = try update.stage(manifest.artifact(), &check.interface, &discard.writer);
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = patch.reader(zio.io(), &read_buffer);
    var bounded = limits;
    bounded.max_result_bytes = @min(limits.max_result_bytes, manifest.result_bytes);
    const result = try apply(source, &reader.interface, output, bounded);
    try output.flush();
    if (result.bytes != manifest.result_bytes or !std.crypto.timing_safe.eql([32]u8, result.sha256, manifest.result_sha256)) return error.HashMismatch;
}

fn roundTrip(allocator: std.mem.Allocator, dir: std.Io.Dir, old: []const u8, new: []const u8) !void {
    var patch: std.Io.Writer.Allocating = .init(allocator);
    defer patch.deinit();
    try diff(allocator, old, new, &patch.writer);
    try dir.writeFile(zio.io(), .{ .sub_path = "old.bin", .data = old });
    var source = try dir.openFile(zio.io(), "old.bin", .{});
    defer source.close(zio.io());
    var reader: std.Io.Reader = .fixed(patch.written());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const applied = try apply(source, &reader, &output.writer, .{});
    try std.testing.expectEqualSlices(u8, new, output.written());
    var digest: [32]u8 = undefined;
    Sha256.hash(new, &digest, .{});
    try std.testing.expectEqual(digest, applied.sha256);
}

test "patches rebuild shifted, edited, truncated and unrelated inputs" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var prng: std.Random.DefaultPrng = .init(7);
    const old = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(old);
    prng.random().bytes(old);
    var shifted = try allocator.alloc(u8, old.len + 3);
    defer allocator.free(shifted);
    @memcpy(shifted[0..3], "abc");
    @memcpy(shifted[3..], old);
    shifted[40000] ^= 0x55;
    try roundTrip(allocator, temp.dir, old, shifted);
    try roundTrip(allocator, temp.dir, old, old[100..5000]);
    try roundTrip(allocator, temp.dir, old, "tiny");
    try roundTrip(allocator, temp.dir, "x", old[0..1000]);
    var patch: std.Io.Writer.Allocating = .init(allocator);
    defer patch.deinit();
    try diff(allocator, old, shifted, &patch.writer);
    // Mostly copies: the patch stays far smaller than the result.
    try std.testing.expect(patch.written().len < 1024);
}

test "malformed patches fail closed before exceeding bounds" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "old.bin", .data = "0123456789" });
    var source = try temp.dir.openFile(zio.io(), "old.bin", .{});
    defer source.close(zio.io());
    const Case = struct { bytes: []const u8, expected: anyerror };
    const header = magic ++ "\x0a\x00\x00\x00\x00\x00\x00\x00" ++ "\x04\x00\x00\x00\x00\x00\x00\x00";
    const cases = [_]Case{
        .{ .bytes = "nope", .expected = error.InvalidPatch },
        .{ .bytes = magic ++ "\x09\x00\x00\x00\x00\x00\x00\x00" ++ "\x01\x00\x00\x00\x00\x00\x00\x00\x00", .expected = error.SourceMismatch },
        .{ .bytes = header ++ "\x01\x08\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00", .expected = error.InvalidPatch },
        .{ .bytes = header ++ "\x02\x05\x00\x00\x00hello\x00", .expected = error.InvalidPatch },
        .{ .bytes = header ++ "\x02\x03\x00\x00\x00abc\x00", .expected = error.InvalidPatch },
        .{ .bytes = header ++ "\x02\x04\x00\x00\x00abcd\x00trailing", .expected = error.InvalidPatch },
        .{ .bytes = header ++ "\x07", .expected = error.InvalidPatch },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.bytes);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.testing.expectError(case.expected, apply(source, &reader, &output.writer, .{}));
    }
    var reader: std.Io.Reader = .fixed(header ++ "\x02\x04\x00\x00\x00abcd\x00");
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.testing.expectError(error.ResultTooLarge, apply(source, &reader, &output.writer, .{ .max_result_bytes = 3 }));
}

test "signed delta binds source, patch and result and accepts rotated keys" {
    const allocator = std.testing.allocator;
    const old_key = try update.Ed25519.KeyPair.generateDeterministic(@splat(41));
    const new_key = try update.Ed25519.KeyPair.generateDeterministic(@splat(42));
    var manifest: Manifest = .{
        .identity = "org.ziggurat.Delta",
        .target = "linux-x86_64",
        .from = .{ .major = 1, .minor = 0, .patch = 0 },
        .to = .{ .major = 1, .minor = 1, .patch = 0 },
        .source_bytes = 10,
        .source_sha256 = @splat(1),
        .url = "https://example.invalid/1.1.0.patch",
        .bytes = 30,
        .sha256 = @splat(2),
        .result_bytes = 12,
        .result_sha256 = @splat(3),
        .signature = undefined,
    };
    const policy: update.Policy = .{ .identity = manifest.identity, .target = manifest.target, .current_version = manifest.from, .public_key = old_key.public_key.toBytes() };
    const json = try sign(allocator, manifest, old_key);
    defer allocator.free(json);
    const verified = try parseAndVerify(allocator, json, policy, @splat(1));
    defer verified.deinit();
    try std.testing.expectError(error.WrongSource, parseAndVerify(allocator, json, policy, @splat(9)));
    var other = policy;
    other.current_version = manifest.to;
    try std.testing.expectError(error.WrongSource, parseAndVerify(allocator, json, other, @splat(1)));
    var changed = verified.manifest;
    changed.result_sha256[0] ^= 1;
    try std.testing.expectError(error.InvalidSignature, verify(changed, policy, @splat(1)));

    // A release signed by a new key verifies only with the old key's endorsement.
    const unendorsed = try sign(allocator, manifest, new_key);
    defer allocator.free(unendorsed);
    try std.testing.expectError(error.InvalidSignature, parseAndVerify(allocator, unendorsed, policy, @splat(1)));
    manifest.endorsement = try update.endorse(manifest.identity, old_key, new_key.public_key.toBytes());
    const endorsed = try sign(allocator, manifest, new_key);
    defer allocator.free(endorsed);
    const rotated = try parseAndVerify(allocator, endorsed, policy, @splat(1));
    defer rotated.deinit();
    var forged = manifest;
    forged.endorsement = try update.endorse(manifest.identity, new_key, new_key.public_key.toBytes());
    forged.endorsement.?.public_key = (try update.Ed25519.KeyPair.generateDeterministic(@splat(43))).public_key.toBytes();
    try std.testing.expectError(error.UntrustedSigningKey, verify(forged, policy, @splat(1)));
    var wrong_identity = manifest;
    wrong_identity.endorsement = try update.endorse("org.ziggurat.Other", old_key, new_key.public_key.toBytes());
    try std.testing.expectError(error.UntrustedSigningKey, verify(wrong_identity, policy, @splat(1)));
}
