const std = @import("std");
const zio = @import("ziggurat_io");
const update = @import("root.zig");
const publication = @import("publication.zig");
const File = struct { name: []const u8, bytes: []const u8 };

fn storedZip(allocator: std.mem.Allocator, files: []const File) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var offsets: [8]u32 = undefined;
    for (files, 0..) |file, index| {
        offsets[index] = @intCast(output.written().len);
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.crc32 = std.hash.Crc32.hash(file.bytes);
        header.compressed_size = @intCast(file.bytes.len);
        header.uncompressed_size = @intCast(file.bytes.len);
        header.filename_len = @intCast(file.name.len);
        try output.writer.writeAll(std.mem.asBytes(&header));
        try output.writer.writeAll(file.name);
        try output.writer.writeAll(file.bytes);
    }
    const central_start = output.written().len;
    for (files, 0..) |file, index| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_needed_to_extract = 20;
        header.version_made_by = 20;
        header.crc32 = std.hash.Crc32.hash(file.bytes);
        header.compressed_size = @intCast(file.bytes.len);
        header.uncompressed_size = @intCast(file.bytes.len);
        header.filename_len = @intCast(file.name.len);
        header.local_file_header_offset = offsets[index];
        try output.writer.writeAll(std.mem.asBytes(&header));
        try output.writer.writeAll(file.name);
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(files.len);
    end.record_count_total = @intCast(files.len);
    end.central_directory_offset = @intCast(central_start);
    end.central_directory_size = @intCast(output.written().len - central_start);
    try output.writer.writeAll(std.mem.asBytes(&end));
    return output.toOwnedSlice();
}
fn metadata(allocator: std.mem.Allocator, app_bytes: []const u8, bad_hash: bool) ![]u8 {
    var app_hash: [32]u8 = undefined;
    var license_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(app_bytes, &app_hash, .{});
    std.crypto.hash.sha2.Sha256.hash("Test fixture only.", &license_hash, .{});
    if (bad_hash) app_hash[0] ^= 1;
    const app_hex = std.fmt.bytesToHex(app_hash, .lower);
    const license_hex = std.fmt.bytesToHex(license_hash, .lower);
    const Payload = struct { path: []const u8, bytes: usize, sha256: []const u8 };
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = 1,
        .identity = "org.ziggurat.UpdateFixture",
        .target = "windows-x86_64",
        .version = "1.0.0.0",
        .executable = "app.exe",
        .files = [_]Payload{
            .{ .path = "app.exe", .bytes = app_bytes.len, .sha256 = &app_hex },
            .{ .path = "LICENSE.txt", .bytes = "Test fixture only.".len, .sha256 = &license_hex },
        },
    }, .{});
}
fn signed(allocator: std.mem.Allocator, archive: []const u8) !update.Verified {
    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(93));
    var manifest: update.Manifest = .{
        .identity = "org.ziggurat.UpdateFixture",
        .target = "windows-x86_64",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .url = "https://updates.example.invalid/test.zip",
        .bytes = archive.len,
        .sha256 = undefined,
        .signature = undefined,
    };
    std.crypto.hash.sha2.Sha256.hash(archive, &manifest.sha256, .{});
    const json = try update.sign(allocator, manifest, key);
    defer allocator.free(json);
    return update.parseAndVerify(allocator, json, .{
        .identity = manifest.identity,
        .target = manifest.target,
        .public_key = key.public_key.toBytes(),
        .current_version = .{ .major = 0, .minor = 0, .patch = 0 },
    });
}

test "authenticated ZIP publication preserves old state and resolves an immutable release" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "user-data.txt", .data = "keep" });
    const package = try metadata(allocator, "new executable", false);
    defer allocator.free(package);
    const archive_bytes = try storedZip(allocator, &.{ .{ .name = "app.exe", .bytes = "new executable" }, .{ .name = "LICENSE.txt", .bytes = "Test fixture only." }, .{ .name = "package.json", .bytes = package } });
    defer allocator.free(archive_bytes);
    const verified = try signed(allocator, archive_bytes);
    defer verified.deinit();
    var archive = try temp.dir.createFile(zio.io(), "download.zip", .{ .read = true });
    defer archive.close(zio.io());
    try archive.writeStreamingAll(zio.io(), archive_bytes);
    {
        var lock = try temp.dir.createFile(zio.io(), "update.lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        defer lock.close(zio.io());
        try std.testing.expectError(error.UpdateInProgress, publication.publishZip(allocator, temp.dir, archive, &verified, .{}));
    }
    try std.testing.expectError(error.ExpandedSizeLimit, publication.publishZip(allocator, temp.dir, archive, &verified, .{ .max_expanded_bytes = 1 }));
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(zio.io(), "current.json", .{}));
    var published = try publication.publishZip(allocator, temp.dir, archive, &verified, .{});
    var path_buffer: [512]u8 = undefined;
    const path = try published.relativePath(&path_buffer);
    const content = try temp.dir.readFileAlloc(zio.io(), path, allocator, .limited(64));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("new executable", content);
    const current = try publication.readCurrent(allocator, temp.dir, verified.manifest.identity, verified.manifest.target);
    try std.testing.expectEqual(published.version, current.version);
    try std.testing.expectError(error.AlreadyPublished, publication.publishZip(allocator, temp.dir, archive, &verified, .{}));
    // Simulate interruption between immutable release rename and marker rename.
    try temp.dir.deleteFile(zio.io(), "current.json");
    _ = try publication.publishZip(allocator, temp.dir, archive, &verified, .{});
    _ = try publication.readCurrent(allocator, temp.dir, verified.manifest.identity, verified.manifest.target);
    try temp.dir.deleteFile(zio.io(), "current.json");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = path, .data = "tampered" });
    try std.testing.expectError(error.ReleaseContentMismatch, publication.publishZip(allocator, temp.dir, archive, &verified, .{}));
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(zio.io(), "current.json", .{}));
    const user_data = try temp.dir.readFileAlloc(zio.io(), "user-data.txt", allocator, .limited(16));
    defer allocator.free(user_data);
    try std.testing.expectEqualStrings("keep", user_data);
    var staging = try temp.dir.openDir(zio.io(), "staging", .{ .iterate = true });
    defer staging.close(zio.io());
    var iterator = staging.iterate();
    try std.testing.expect((try iterator.next(zio.io())) == null);
}

test "signed malicious archive names and mismatched inventory never publish" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "../escape.exe", "APP.exe", "app.exe" }, 0..) |bad_name, index| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        const package = try metadata(allocator, "fixture", true);
        defer allocator.free(package);
        const archive_bytes = if (index == 2) try storedZip(allocator, &.{ .{ .name = bad_name, .bytes = "fixture" }, .{ .name = "LICENSE.txt", .bytes = "Test fixture only." }, .{ .name = "package.json", .bytes = package } }) else try storedZip(allocator, &.{ .{ .name = "app.exe", .bytes = "fixture" }, .{ .name = bad_name, .bytes = "fixture" }, .{ .name = "package.json", .bytes = package } });
        defer allocator.free(archive_bytes);
        const verified = try signed(allocator, archive_bytes);
        defer verified.deinit();
        var archive = try temp.dir.createFile(zio.io(), "download.zip", .{ .read = true });
        defer archive.close(zio.io());
        try archive.writeStreamingAll(zio.io(), archive_bytes);
        const expected = [_]anyerror{ error.InvalidPayloadName, error.DuplicatePayloadName, error.HashMismatch };
        try std.testing.expectError(expected[index], publication.publishZip(allocator, temp.dir, archive, &verified, .{}));
        try std.testing.expectError(error.FileNotFound, temp.dir.openFile(zio.io(), "current.json", .{}));
    }
}

fn expectEmptyStage(root: std.Io.Dir) !void {
    var staging = root.openDir(zio.io(), "staging", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer staging.close(zio.io());
    var iterator = staging.iterate();
    try std.testing.expect((try iterator.next(zio.io())) == null);
}

test "publication allocation failures remove staging and preserve the previous marker" {
    const Fixture = struct {
        const old_marker =
            \\{"format":1,"identity":"org.ziggurat.UpdateFixture","target":"windows-x86_64","version":{"major":0,"minor":9,"patch":0,"revision":0},"release":"windows-x86_64-0.9.0.0","executable":"app.exe"}
        ;
        fn run(allocator: std.mem.Allocator, has_current: bool) !void {
            // Fixture construction and assertions use a separate allocator; the
            // sweep fails every allocation made by publication itself.
            const fixture_allocator = std.testing.allocator;
            var temporary = std.testing.tmpDir(.{ .iterate = true });
            defer temporary.cleanup();
            try temporary.dir.writeFile(zio.io(), .{ .sub_path = "user-data.txt", .data = "keep" });
            if (has_current) {
                try temporary.dir.createDirPath(zio.io(), "releases/windows-x86_64-0.9.0.0");
                try temporary.dir.writeFile(zio.io(), .{ .sub_path = "releases/windows-x86_64-0.9.0.0/app.exe", .data = "old executable" });
                try temporary.dir.writeFile(zio.io(), .{ .sub_path = "current.json", .data = old_marker });
            }
            const package = try metadata(fixture_allocator, "new executable", false);
            defer fixture_allocator.free(package);
            const archive_bytes = try storedZip(fixture_allocator, &.{
                .{ .name = "app.exe", .bytes = "new executable" },
                .{ .name = "LICENSE.txt", .bytes = "Test fixture only." },
                .{ .name = "package.json", .bytes = package },
            });
            defer fixture_allocator.free(archive_bytes);
            const verified = try signed(fixture_allocator, archive_bytes);
            defer verified.deinit();
            var archive = try temporary.dir.createFile(zio.io(), "download.zip", .{ .read = true });
            defer archive.close(zio.io());
            try archive.writeStreamingAll(zio.io(), archive_bytes);
            var published = publication.publishZip(allocator, temporary.dir, archive, &verified, .{}) catch |err| {
                if (err != error.OutOfMemory) return err;
                try expectEmptyStage(temporary.dir);
                if (has_current) {
                    const current = try temporary.dir.readFileAlloc(zio.io(), "current.json", fixture_allocator, .limited(4096));
                    defer fixture_allocator.free(current);
                    try std.testing.expectEqualStrings(old_marker, current);
                } else try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(zio.io(), "current.json", .{}));
                var iterator = temporary.dir.iterate();
                while (try iterator.next(zio.io())) |entry| {
                    if (std.mem.eql(u8, entry.name, "current.json") or std.mem.eql(u8, entry.name, "download.zip") or std.mem.eql(u8, entry.name, "user-data.txt") or std.mem.eql(u8, entry.name, "update.lock") or std.mem.eql(u8, entry.name, "releases") or std.mem.eql(u8, entry.name, "staging")) continue;
                    return error.UnexpectedPublicationResidue;
                }
                // No failed attempt may leave the update lock held.
                var lock = try temporary.dir.createFile(zio.io(), "update.lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
                lock.close(zio.io());
                if (has_current) {
                    const old = try temporary.dir.readFileAlloc(zio.io(), "releases/windows-x86_64-0.9.0.0/app.exe", fixture_allocator, .limited(64));
                    defer fixture_allocator.free(old);
                    try std.testing.expectEqualStrings("old executable", old);
                }
                return err;
            };
            try expectEmptyStage(temporary.dir);
            var path_buffer: [512]u8 = undefined;
            const bytes = try temporary.dir.readFileAlloc(zio.io(), try published.relativePath(&path_buffer), fixture_allocator, .limited(64));
            defer fixture_allocator.free(bytes);
            try std.testing.expectEqualStrings("new executable", bytes);
            const current = try publication.readCurrent(fixture_allocator, temporary.dir, verified.manifest.identity, verified.manifest.target);
            try std.testing.expectEqual(verified.manifest.version, current.version);
            const user_data = try temporary.dir.readFileAlloc(zio.io(), "user-data.txt", fixture_allocator, .limited(16));
            defer fixture_allocator.free(user_data);
            try std.testing.expectEqualStrings("keep", user_data);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{true});
}
