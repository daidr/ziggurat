const std = @import("std");
const update = @import("ziggurat_update");

const usage =
    \\ziggurat-update keygen PRIVATE_SEED_FILE PUBLIC_KEY_FILE
    \\ziggurat-update sign ZIP MANIFEST PRIVATE_SEED_FILE ID TARGET VERSION HTTPS_URL [ENDORSEMENT]
    \\ziggurat-update verify MANIFEST PUBLIC_KEY_FILE ID TARGET CURRENT_VERSION
    \\ziggurat-update publish MANIFEST PUBLIC_KEY_FILE ID TARGET CURRENT_VERSION ZIP ROOT
    \\ziggurat-update current ROOT ID TARGET
    \\ziggurat-update pack OUTPUT_ZIP NAME ID TARGET VERSION EXECUTABLE FILE...
    \\ziggurat-update endorse TRUSTED_SEED_FILE NEW_PUBLIC_KEY_FILE ID ENDORSEMENT
    \\ziggurat-update release DIR ID TARGET VERSION ZIP PRIVATE_SEED_FILE BASE_HTTPS_URL [--endorsement FILE] [--from OLD_ZIP OLD_VERSION]...
    \\ziggurat-update check FEED PUBLIC_KEY_FILE ID TARGET ROOT
    \\ziggurat-update fetch FEED PUBLIC_KEY_FILE ID TARGET ROOT
    \\ziggurat-update rollback ROOT ID TARGET VERSION
    \\ziggurat-update prune ROOT ID TARGET KEEP
    \\Versions have four decimal components. Key files contain exactly 32 raw bytes.
    \\Use a protected signing directory; never distribute the private seed.
    \\FEED is an https:// URL or a local file. fetch prefers a signed delta from
    \\the retained archive and falls back to the full archive, then publishes.
    \\release writes signed manifests, patches and feed.json for static hosting;
    \\rerunning with the same inputs is a no-op and conflicting assets fail.
    \\Publication performs blocking disk I/O and never overwrites a running release.
    \\Application shutdown and restart belong to the host.
    \\
;

pub fn main() void {
    run() catch |err| {
        std.debug.print("update: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn out(text: []const u8) !void {
    try std.fs.File.stdout().writeAll(text);
}

fn run() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len == 1 or std.mem.eql(u8, args[1], "--help")) return out(usage);
    const cwd = std.fs.cwd();
    const command = args[1];
    if (std.mem.eql(u8, command, "keygen")) {
        if (args.len != 4) return error.InvalidArguments;
        var key = update.Ed25519.KeyPair.generate();
        defer std.crypto.secureZero(u8, &key.secret_key.bytes);
        var seed = key.secret_key.seed();
        defer std.crypto.secureZero(u8, &seed);
        var secret = try cwd.createFile(args[2], .{ .exclusive = true, .mode = 0o600 });
        defer secret.close();
        errdefer cwd.deleteFile(args[2]) catch {};
        try secret.writeAll(&seed);
        try secret.sync();
        var public = try cwd.createFile(args[3], .{ .exclusive = true });
        defer public.close();
        errdefer cwd.deleteFile(args[3]) catch {};
        try public.writeAll(&key.public_key.toBytes());
        try public.sync();
    } else if (std.mem.eql(u8, command, "sign")) {
        if (args.len != 9 and args.len != 10) return error.InvalidArguments;
        var key = try loadKeyPair(args[4]);
        defer std.crypto.secureZero(u8, &key.secret_key.bytes);
        const digest = try hashPath(args[2]);
        const endorsement = if (args.len == 10) try readEndorsement(allocator, args[9]) else null;
        const json = try update.sign(allocator, .{
            .identity = args[5],
            .target = args[6],
            .version = try update.retention.parseVersion(args[7]),
            .url = args[8],
            .bytes = digest.bytes,
            .sha256 = digest.sha256,
            .signature = @splat(0),
            .endorsement = endorsement,
        }, key);
        // An explicit output path is exclusive: publication cannot silently replace metadata.
        try writeExclusive(args[3], json);
    } else if (std.mem.eql(u8, command, "verify") or std.mem.eql(u8, command, "publish")) {
        const publish = std.mem.eql(u8, command, "publish");
        if (args.len != (if (publish) @as(usize, 9) else 7)) return error.InvalidArguments;
        const bytes = try cwd.readFileAlloc(allocator, args[2], 16384);
        const verified = try update.parseAndVerify(allocator, bytes, .{
            .public_key = try readKey(args[3]),
            .identity = args[4],
            .target = args[5],
            .current_version = try update.retention.parseVersion(args[6]),
        });
        defer verified.deinit();
        if (publish) {
            var archive = try cwd.openFile(args[7], .{});
            defer archive.close();
            var root = try cwd.makeOpenPath(args[8], .{ .no_follow = true });
            defer root.close();
            const result = try update.publication.publishZip(allocator, root, archive, &verified, .{ .retain_archive = true });
            try printPublished(result);
        } else try out("verified\n");
    } else if (std.mem.eql(u8, command, "current")) {
        if (args.len != 5) return error.InvalidArguments;
        var root = try cwd.openDir(args[2], .{ .no_follow = true });
        defer root.close();
        try printPublished(try update.publication.readCurrent(allocator, root, args[3], args[4]));
    } else if (std.mem.eql(u8, command, "pack")) {
        if (args.len < 9) return error.InvalidArguments;
        const entries = try allocator.alloc(update.archive.Entry, args.len - 8);
        for (args[8..], entries) |path, *entry| entry.* = .{ .name = std.fs.path.basename(path), .bytes = try cwd.readFileAlloc(allocator, path, 512 * 1024 * 1024) };
        const zip = try update.archive.buildPackage(allocator, .{ .name = args[3], .identity = args[4], .target = args[5], .version = try update.retention.parseVersion(args[6]), .executable = args[7] }, entries);
        try writeExclusive(args[2], zip);
    } else if (std.mem.eql(u8, command, "endorse")) {
        if (args.len != 6) return error.InvalidArguments;
        var key = try loadKeyPair(args[2]);
        defer std.crypto.secureZero(u8, &key.secret_key.bytes);
        const endorsement = try update.endorse(args[4], key, try readKey(args[3]));
        const hex: update.EndorsementHex = .init(endorsement);
        try writeExclusive(args[5], try std.json.Stringify.valueAlloc(allocator, hex.wire(), .{ .whitespace = .indent_2 }));
    } else if (std.mem.eql(u8, command, "release")) {
        try release(allocator, args);
    } else if (std.mem.eql(u8, command, "check") or std.mem.eql(u8, command, "fetch")) {
        if (args.len != 7) return error.InvalidArguments;
        try checkOrFetch(allocator, args, std.mem.eql(u8, command, "fetch"));
    } else if (std.mem.eql(u8, command, "rollback")) {
        if (args.len != 6) return error.InvalidArguments;
        var root = try cwd.openDir(args[2], .{ .no_follow = true });
        defer root.close();
        try printPublished(try update.retention.rollback(allocator, root, args[3], args[4], try update.retention.parseVersion(args[5])));
    } else if (std.mem.eql(u8, command, "prune")) {
        if (args.len != 6) return error.InvalidArguments;
        var root = try cwd.openDir(args[2], .{ .no_follow = true });
        defer root.close();
        const removed = try update.retention.prune(allocator, root, args[3], args[4], try std.fmt.parseInt(usize, args[5], 10));
        try out(try std.fmt.allocPrint(allocator, "removed {d}\n", .{removed}));
    } else return error.UnknownCommand;
}

fn printPublished(result: update.publication.Published) !void {
    var path_buffer: [512]u8 = undefined;
    try out(try result.relativePath(&path_buffer));
    try out("\n");
}

fn writeExclusive(path: []const u8, bytes: []const u8) !void {
    var output = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer output.close();
    errdefer std.fs.cwd().deleteFile(path) catch {};
    try output.writeAll(bytes);
    try output.sync();
}

/// Idempotent release asset: identical existing bytes are kept, others conflict.
fn writeAsset(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !bool {
    if (dir.openFile(name, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.size == bytes.len) {
            var existing_hash: [32]u8 = undefined;
            var new_hash: [32]u8 = undefined;
            const existing = try hashFile(file);
            existing_hash = existing.sha256;
            std.crypto.hash.sha2.Sha256.hash(bytes, &new_hash, .{});
            if (std.mem.eql(u8, &existing_hash, &new_hash)) return false;
        }
        std.debug.print("update: {s} already exists with different content\n", .{name});
        return error.AssetConflict;
    } else |err| if (err != error.FileNotFound) return err;
    var atomic_buffer: [16 * 1024]u8 = undefined;
    var atomic = try dir.atomicFile(name, .{ .write_buffer = &atomic_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.flush();
    try atomic.file_writer.file.sync();
    try atomic.renameIntoPlace();
    return true;
}

fn versionText(allocator: std.mem.Allocator, v: update.Version) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ v.major, v.minor, v.patch, v.revision });
}

fn joinUrl(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base, if (std.mem.endsWith(u8, base, "/")) "" else "/", name });
}

fn release(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 9) return error.InvalidArguments;
    const identity = args[3];
    const target = args[4];
    const version = try update.retention.parseVersion(args[5]);
    const zip = try std.fs.cwd().readFileAlloc(allocator, args[6], 512 * 1024 * 1024);
    var key = try loadKeyPair(args[7]);
    defer std.crypto.secureZero(u8, &key.secret_key.bytes);
    const base = args[8];
    var endorsement: ?update.Endorsement = null;
    var previous: std.ArrayList(struct { path: []const u8, version: update.Version }) = .empty;
    var index: usize = 9;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--endorsement") and index + 1 < args.len) {
            endorsement = try readEndorsement(allocator, args[index + 1]);
            index += 1;
        } else if (std.mem.eql(u8, args[index], "--from") and index + 2 < args.len) {
            try previous.append(allocator, .{ .path = args[index + 1], .version = try update.retention.parseVersion(args[index + 2]) });
            index += 2;
        } else return error.InvalidArguments;
    }
    var dir = try std.fs.cwd().makeOpenPath(args[2], .{ .iterate = true });
    defer dir.close();
    const v = try versionText(allocator, version);
    const zip_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.zip", .{ identity, target, v });
    var manifest: update.Manifest = .{ .identity = identity, .target = target, .version = version, .url = try joinUrl(allocator, base, zip_name), .bytes = zip.len, .sha256 = undefined, .signature = @splat(0), .endorsement = endorsement };
    std.crypto.hash.sha2.Sha256.hash(zip, &manifest.sha256, .{});
    // Ed25519 signing is deterministic, so a retry reproduces identical manifests.
    const full_json = try update.sign(allocator, manifest, key);
    _ = try writeAsset(dir, zip_name, zip);
    _ = try writeAsset(dir, try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.json", .{ identity, target, v }), full_json);
    for (previous.items) |old| {
        if (old.version.order(version) != .lt) return error.InvalidArguments;
        const source = try std.fs.cwd().readFileAlloc(allocator, old.path, 512 * 1024 * 1024);
        var patch: std.Io.Writer.Allocating = .init(allocator);
        try update.delta.diff(allocator, source, zip, &patch.writer);
        // A patch that saves little is not worth a second download path.
        if (patch.written().len >= zip.len * 9 / 10) continue;
        const ov = try versionText(allocator, old.version);
        const patch_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-to-{s}.patch", .{ identity, target, ov, v });
        var signed_patch: update.delta.Manifest = .{ .identity = identity, .target = target, .from = old.version, .to = version, .source_bytes = source.len, .source_sha256 = undefined, .url = try joinUrl(allocator, base, patch_name), .bytes = patch.written().len, .sha256 = undefined, .result_bytes = manifest.bytes, .result_sha256 = manifest.sha256, .signature = @splat(0), .endorsement = endorsement };
        std.crypto.hash.sha2.Sha256.hash(source, &signed_patch.source_sha256, .{});
        std.crypto.hash.sha2.Sha256.hash(patch.written(), &signed_patch.sha256, .{});
        _ = try writeAsset(dir, patch_name, patch.written());
        _ = try writeAsset(dir, try std.fmt.allocPrint(allocator, "{s}.json", .{patch_name}), try update.delta.sign(allocator, signed_patch, key));
    }
    // The feed indexes every manifest in the directory for this identity.
    var releases: std.ArrayList([]const u8) = .empty;
    var deltas: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json") or std.mem.eql(u8, entry.name, "feed.json")) continue;
        if (!std.mem.startsWith(u8, entry.name, identity) or entry.name.len <= identity.len or entry.name[identity.len] != '-') continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (names.items) |name| {
        const text = try dir.readFileAlloc(allocator, name, 16384);
        if (std.mem.endsWith(u8, name, ".patch.json")) try deltas.append(allocator, text) else try releases.append(allocator, text);
    }
    const feed_json = try update.feed.build(allocator, identity, releases.items, deltas.items);
    var atomic_buffer: [16 * 1024]u8 = undefined;
    var atomic = try dir.atomicFile("feed.json", .{ .write_buffer = &atomic_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(feed_json);
    try atomic.flush();
    try atomic.renameIntoPlace();
    try out(try std.fmt.allocPrint(allocator, "{s}\n", .{zip_name}));
}

fn readFeed(allocator: std.mem.Allocator, client: *std.http.Client, location: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, location, "https://")) return update.http.get(allocator, client, location, update.feed.max_feed_bytes);
    return std.fs.cwd().readFileAlloc(allocator, location, update.feed.max_feed_bytes);
}

fn printProgress(_: ?*anyopaque, progress: update.download.Progress) void {
    std.debug.print("\r{d}/{d} bytes", .{ progress.received, progress.total });
    if (progress.received == progress.total) std.debug.print("\n", .{});
}

fn checkOrFetch(allocator: std.mem.Allocator, args: []const []const u8, fetch: bool) !void {
    var root = try std.fs.cwd().makeOpenPath(args[6], .{ .iterate = true, .no_follow = true });
    defer root.close();
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    const identity = args[4];
    const target = args[5];
    var policy: update.Policy = .{ .identity = identity, .target = target, .current_version = .{ .major = 0, .minor = 0, .patch = 0 }, .public_key = try readKey(args[3]) };
    var retained: ?update.retention.Retained = null;
    defer if (retained) |value| value.file.close();
    if (update.publication.readCurrent(allocator, root, identity, target)) |current| {
        policy.current_version = current.version;
        retained = try update.retention.currentArchive(allocator, root, identity, target);
    } else |err| if (err != error.FileNotFound) return err;
    const feed_bytes = try readFeed(allocator, &client, args[2]);
    const result = try update.feed.check(allocator, feed_bytes, policy, if (retained) |value| .{ .sha256 = value.sha256 } else null);
    defer result.deinit();
    const available = switch (result) {
        .current => return out("current\n"),
        .available => |value| value,
    };
    const v = available.full.manifest.version;
    try out(try std.fmt.allocPrint(allocator, "available {d}.{d}.{d}.{d}{s}\n", .{ v.major, v.minor, v.patch, v.revision, if (available.delta != null) " (delta)" else "" }));
    if (!fetch) return;
    var downloads = try root.makeOpenPath("downloads", .{ .no_follow = true });
    defer downloads.close();
    var control: update.download.Control = .{ .on_progress = printProgress };
    var http_source: update.http.Source = .init(&client);
    const archive_name = try std.fmt.allocPrint(allocator, "{s}-{d}.{d}.{d}.{d}.zip", .{ target, v.major, v.minor, v.patch, v.revision });
    var archive = try downloads.createFile(archive_name, .{ .read = true, .truncate = false });
    defer archive.close();
    var rebuilt = false;
    if (available.delta) |patch| delta: {
        var patch_file = try downloads.createFile(try std.fmt.allocPrint(allocator, "{s}.patch", .{archive_name}), .{ .read = true, .truncate = false });
        defer patch_file.close();
        _ = update.download.fetch(patch.manifest.artifact(), http_source.source(), patch_file, &control) catch |err| {
            std.debug.print("update: delta download failed ({s}); using the full archive\n", .{@errorName(err)});
            break :delta;
        };
        try archive.setEndPos(0);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = archive.writer(&buffer);
        update.delta.applyVerified(&patch, available.full.manifest, retained.?.file, patch_file, &writer.interface, .{}) catch |err| {
            std.debug.print("update: delta rejected ({s}); using the full archive\n", .{@errorName(err)});
            try archive.setEndPos(0);
            break :delta;
        };
        rebuilt = true;
    }
    if (!rebuilt) _ = try update.download.fetch(available.full.manifest, http_source.source(), archive, &control);
    const published = try update.publication.publishZip(allocator, root, archive, &available.full, .{ .retain_archive = true });
    try printPublished(published);
    downloads.deleteFile(archive_name) catch {};
}

fn readEndorsement(allocator: std.mem.Allocator, path: []const u8) !update.Endorsement {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    const parsed = try std.json.parseFromSliceLeaky(update.EndorsementWire, allocator, bytes, .{ .duplicate_field_behavior = .@"error" });
    return (try update.decodeEndorsement(parsed)).?;
}

fn loadKeyPair(path: []const u8) !update.Ed25519.KeyPair {
    var seed = try readKey(path);
    defer std.crypto.secureZero(u8, &seed);
    return update.Ed25519.KeyPair.generateDeterministic(seed);
}

const Digest = struct { bytes: u64, sha256: [32]u8 };
fn hashFile(file: std.fs.File) !Digest {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var bytes: u64 = 0;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try file.pread(&chunk, bytes);
        if (n == 0) break;
        hash.update(chunk[0..n]);
        bytes = try std.math.add(u64, bytes, n);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .bytes = bytes, .sha256 = digest };
}
fn hashPath(path: []const u8) !Digest {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return hashFile(file);
}

fn readKey(path: []const u8) ![32]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    if ((try file.stat()).size != 32) return error.InvalidKeyLength;
    var bytes: [32]u8 = undefined;
    if (try file.readAll(&bytes) != bytes.len) return error.InvalidKeyLength;
    return bytes;
}
