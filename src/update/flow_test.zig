const std = @import("std");
const update = @import("root.zig");
const archive = update.archive;
const delta = update.delta;
const feed = update.feed;
const download = update.download;
const publication = update.publication;
const retention = update.retention;

const identity = "org.ziggurat.Flow";
const target = "linux-x86_64";

fn version(minor: u16) update.Version {
    return .{ .major = 1, .minor = minor, .patch = 0 };
}

fn package(allocator: std.mem.Allocator, minor: u16, body: []const u8) ![]u8 {
    return archive.buildPackage(allocator, .{ .name = "Flow", .identity = identity, .target = target, .version = version(minor), .executable = "app" }, &.{
        .{ .name = "app", .bytes = body },
        .{ .name = "LICENSE.txt", .bytes = "Test fixture only." },
    });
}

fn fullManifest(bytes: []const u8, minor: u16) update.Manifest {
    var manifest: update.Manifest = .{ .identity = identity, .target = target, .version = version(minor), .url = "https://updates.example.invalid/full.zip", .bytes = bytes.len, .sha256 = undefined, .signature = undefined };
    std.crypto.hash.sha2.Sha256.hash(bytes, &manifest.sha256, .{});
    return manifest;
}

test "full install, delta upgrade with full fallback, rollback and pruning" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var root = try temp.dir.makeOpenPath("root", .{ .iterate = true });
    defer root.close();
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(61));
    const base_policy: update.Policy = .{ .identity = identity, .target = target, .current_version = .{ .major = 0, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() };

    var bodies: [3][]u8 = undefined;
    var archives: [3][]u8 = undefined;
    for (0..3) |index| {
        bodies[index] = try allocator.alloc(u8, 40 * 1024);
        var prng: std.Random.DefaultPrng = .init(99);
        prng.random().bytes(bodies[index]);
        bodies[index][index * 1000] = @intCast(index);
        archives[index] = try package(allocator, @intCast(index), bodies[index]);
    }
    defer for (bodies, archives) |body, bytes| {
        allocator.free(body);
        allocator.free(bytes);
    };

    // Version 1.0 is installed with its archive retained.
    {
        const json = try update.sign(allocator, fullManifest(archives[0], 0), key);
        defer allocator.free(json);
        const verified = try update.parseAndVerify(allocator, json, base_policy);
        defer verified.deinit();
        try root.writeFile(.{ .sub_path = "download.zip", .data = archives[0] });
        var file = try root.openFile("download.zip", .{});
        defer file.close();
        _ = try publication.publishZip(allocator, root, file, &verified, .{ .retain_archive = true });
    }

    // Release 1.1 with a delta from 1.0, published in a feed.
    var patch_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer patch_bytes.deinit();
    try delta.diff(allocator, archives[0], archives[1], &patch_bytes.writer);
    try std.testing.expect(patch_bytes.written().len < archives[1].len / 4);
    var source_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archives[0], &source_digest, .{});
    const full = fullManifest(archives[1], 1);
    var patch: delta.Manifest = .{ .identity = identity, .target = target, .from = version(0), .to = version(1), .source_bytes = archives[0].len, .source_sha256 = source_digest, .url = "https://updates.example.invalid/1.0-1.1.patch", .bytes = patch_bytes.written().len, .sha256 = undefined, .result_bytes = full.bytes, .result_sha256 = full.sha256, .signature = undefined };
    std.crypto.hash.sha2.Sha256.hash(patch_bytes.written(), &patch.sha256, .{});
    const full_json = try update.sign(allocator, full, key);
    defer allocator.free(full_json);
    const patch_json = try delta.sign(allocator, patch, key);
    defer allocator.free(patch_json);
    const feed_json = try feed.build(allocator, identity, &.{full_json}, &.{patch_json});
    defer allocator.free(feed_json);

    const retained = (try retention.currentArchive(allocator, root, identity, target)).?;
    defer retained.file.close();
    try std.testing.expectEqual(source_digest, retained.sha256);
    var policy = base_policy;
    policy.current_version = retained.version;
    const result = try feed.check(allocator, feed_json, policy, .{ .sha256 = retained.sha256 });
    defer result.deinit();
    const available = result.available;
    const chosen = available.delta.?;

    // Download the patch through the resumable transfer and rebuild 1.1.
    var memory: download.MemorySource = .{ .bytes = patch_bytes.written() };
    var control: download.Control = .{};
    var patch_file = try root.createFile("patch.partial", .{ .read = true });
    defer patch_file.close();
    _ = try download.fetch(chosen.manifest.artifact(), memory.source(), patch_file, &control);
    var rebuilt = try root.createFile("rebuilt.zip", .{ .read = true });
    defer rebuilt.close();
    {
        var buffer: [4096]u8 = undefined;
        var writer = rebuilt.writer(&buffer);
        try delta.applyVerified(&chosen, available.full.manifest, retained.file, patch_file, &writer.interface, .{});
    }
    // A corrupted patch is rejected, leaving the full download as fallback.
    {
        try root.writeFile(.{ .sub_path = "bad.patch", .data = patch_bytes.written() });
        var bad = try root.openFile("bad.patch", .{ .mode = .read_write });
        defer bad.close();
        try bad.pwriteAll("X", 40);
        var sink: std.Io.Writer.Allocating = .init(allocator);
        defer sink.deinit();
        try std.testing.expectError(error.HashMismatch, delta.applyVerified(&chosen, available.full.manifest, retained.file, bad, &sink.writer, .{}));
    }
    const published = try publication.publishZip(allocator, root, rebuilt, &available.full, .{ .retain_archive = true });
    try std.testing.expectEqual(version(1), published.version);

    // 1.2 as a full update only.
    {
        const json = try update.sign(allocator, fullManifest(archives[2], 2), key);
        defer allocator.free(json);
        policy.current_version = version(1);
        const verified = try update.parseAndVerify(allocator, json, policy);
        defer verified.deinit();
        try root.writeFile(.{ .sub_path = "download.zip", .data = archives[2] });
        var file = try root.openFile("download.zip", .{});
        defer file.close();
        _ = try publication.publishZip(allocator, root, file, &verified, .{ .retain_archive = true });
    }
    const versions = try retention.list(allocator, root, target);
    defer allocator.free(versions);
    try std.testing.expectEqualSlices(update.Version, &.{ version(0), version(1), version(2) }, versions);

    // Rollback re-checks the retained release; tampering blocks it.
    try root.writeFile(.{ .sub_path = "releases/linux-x86_64-1.0.0.0/app", .data = "tampered" });
    try std.testing.expectError(error.SizeMismatch, retention.rollback(allocator, root, identity, target, version(0)));
    const back = try retention.rollback(allocator, root, identity, target, version(1));
    try std.testing.expectEqual(version(1), back.version);
    try std.testing.expectEqual(version(1), (try publication.readCurrent(allocator, root, identity, target)).version);
    try std.testing.expectError(error.ReleaseNotRetained, retention.rollback(allocator, root, identity, target, version(7)));

    // Pruning keeps the current release and anything newer.
    try std.testing.expectEqual(1, try retention.prune(allocator, root, identity, target, 1));
    const left = try retention.list(allocator, root, target);
    defer allocator.free(left);
    try std.testing.expectEqualSlices(update.Version, &.{ version(1), version(2) }, left);
    try std.testing.expectError(error.FileNotFound, root.openFile("archives/linux-x86_64-1.0.0.0.zip", .{}));
}
