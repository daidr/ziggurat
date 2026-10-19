const std = @import("std");
const update = @import("root.zig");
const publication = @import("publication.zig");

pub const Entry = struct { name: []const u8, bytes: []const u8 };

/// Fixed DOS date 1980-01-01 so equal inputs produce equal archives.
const dos_date: u16 = (1 << 5) | 1;

/// Write a stored (uncompressed) ZIP with entries in the given order.
/// Names must be flat release names; ZIP64 is not produced.
pub fn writeStored(writer: *std.Io.Writer, entries: []const Entry) !void {
    if (entries.len == 0 or entries.len > 0xffff) return error.TooManyPayloadFiles;
    var offset: u64 = 0;
    for (entries) |entry| {
        try publication.validateFilename(entry.name);
        if (entry.bytes.len >= 0xffff_ffff) return error.ArchiveTooLarge;
        var header = std.mem.zeroes(std.zip.LocalFileHeader);
        header.signature = std.zip.local_file_header_sig;
        header.version_needed_to_extract = 20;
        header.last_modification_date = dos_date;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.name.len);
        try writer.writeAll(std.mem.asBytes(&header));
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.bytes);
        offset += @sizeOf(std.zip.LocalFileHeader) + entry.name.len + entry.bytes.len;
        if (offset >= 0xffff_ffff) return error.ArchiveTooLarge;
    }
    const central_start = offset;
    var local: u64 = 0;
    for (entries) |entry| {
        var header = std.mem.zeroes(std.zip.CentralDirectoryFileHeader);
        header.signature = std.zip.central_file_header_sig;
        header.version_needed_to_extract = 20;
        header.version_made_by = 20;
        header.last_modification_date = dos_date;
        header.crc32 = std.hash.Crc32.hash(entry.bytes);
        header.compressed_size = @intCast(entry.bytes.len);
        header.uncompressed_size = @intCast(entry.bytes.len);
        header.filename_len = @intCast(entry.name.len);
        header.local_file_header_offset = @intCast(local);
        try writer.writeAll(std.mem.asBytes(&header));
        try writer.writeAll(entry.name);
        local += @sizeOf(std.zip.LocalFileHeader) + entry.name.len + entry.bytes.len;
        offset += @sizeOf(std.zip.CentralDirectoryFileHeader) + entry.name.len;
    }
    var end = std.mem.zeroes(std.zip.EndRecord);
    end.signature = std.zip.end_record_sig;
    end.record_count_disk = @intCast(entries.len);
    end.record_count_total = @intCast(entries.len);
    end.central_directory_offset = @intCast(central_start);
    end.central_directory_size = @intCast(offset - central_start);
    try writer.writeAll(std.mem.asBytes(&end));
}

pub const PackageInfo = struct {
    name: []const u8,
    identity: []const u8,
    target: []const u8,
    version: update.Version,
    executable: []const u8,
};

const Payload = struct { path: []const u8, bytes: u64, sha256: []const u8 };

/// Build an update package: payload files plus a package.json inventory that
/// `publication.publishZip` accepts. Entries are sorted by name; the caller
/// keeps ownership of `files`. The returned archive is caller-owned.
pub fn buildPackage(allocator: std.mem.Allocator, info: PackageInfo, files: []const Entry) ![]u8 {
    if (files.len == 0 or files.len >= 128) return error.TooManyPayloadFiles;
    const sorted = try allocator.alloc(Entry, files.len + 1);
    defer allocator.free(sorted);
    const payload = try allocator.alloc(Payload, files.len);
    defer allocator.free(payload);
    const digests = try allocator.alloc([64]u8, files.len);
    defer allocator.free(digests);
    @memcpy(sorted[0..files.len], files);
    std.mem.sort(Entry, sorted[0..files.len], {}, lessThan);
    var found_executable = false;
    for (sorted[0..files.len], payload, digests, 0..) |entry, *item, *hex, index| {
        try publication.validateFilename(entry.name);
        if (std.ascii.eqlIgnoreCase(entry.name, "package.json")) return error.InventoryMismatch;
        if (index > 0 and std.ascii.eqlIgnoreCase(sorted[index - 1].name, entry.name)) return error.DuplicatePayloadName;
        if (std.mem.eql(u8, entry.name, info.executable)) found_executable = true;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &digest, .{});
        hex.* = std.fmt.bytesToHex(digest, .lower);
        item.* = .{ .path = entry.name, .bytes = entry.bytes.len, .sha256 = hex };
    }
    if (!found_executable) return error.MissingExecutable;
    var version_buffer: [32]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buffer, "{d}.{d}.{d}.{d}", .{ info.version.major, info.version.minor, info.version.patch, info.version.revision });
    const inventory = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = 1,
        .name = info.name,
        .identity = info.identity,
        .version = version,
        .target = info.target,
        .executable = info.executable,
        .files = payload,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(inventory);
    sorted[files.len] = .{ .name = "package.json", .bytes = inventory };
    std.mem.sort(Entry, sorted, {}, lessThan);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeStored(&output.writer, sorted);
    return output.toOwnedSlice();
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

test "stored package round-trips through publication and is deterministic" {
    const allocator = std.testing.allocator;
    const info: PackageInfo = .{ .name = "Fixture", .identity = "org.ziggurat.ArchiveFixture", .target = "linux-x86_64", .version = .{ .major = 2, .minor = 0, .patch = 1 }, .executable = "app" };
    const files = [_]Entry{ .{ .name = "app", .bytes = "#!/bin/sh\necho ok\n" }, .{ .name = "LICENSE.txt", .bytes = "Test fixture only." } };
    const first = try buildPackage(allocator, info, &files);
    defer allocator.free(first);
    const second = try buildPackage(allocator, info, &.{ files[1], files[0] });
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectError(error.MissingExecutable, buildPackage(allocator, .{ .name = "x", .identity = info.identity, .target = info.target, .version = info.version, .executable = "missing" }, &files));
    try std.testing.expectError(error.InvalidPayloadName, buildPackage(allocator, info, &.{ files[0], .{ .name = "../x", .bytes = "" } }));

    const key = try update.Ed25519.KeyPair.generateDeterministic(@splat(5));
    var manifest: update.Manifest = .{ .identity = info.identity, .target = info.target, .version = info.version, .url = "https://example.invalid/a.zip", .bytes = first.len, .sha256 = undefined, .signature = undefined };
    std.crypto.hash.sha2.Sha256.hash(first, &manifest.sha256, .{});
    const json = try update.sign(allocator, manifest, key);
    defer allocator.free(json);
    const verified = try update.parseAndVerify(allocator, json, .{ .identity = info.identity, .target = info.target, .current_version = .{ .major = 1, .minor = 0, .patch = 0 }, .public_key = key.public_key.toBytes() });
    defer verified.deinit();
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var file = try temp.dir.createFile("download.zip", .{ .read = true });
    defer file.close();
    try file.writeAll(first);
    const published = try publication.publishZip(allocator, temp.dir, file, &verified, .{});
    var buffer: [512]u8 = undefined;
    const bytes = try temp.dir.readFileAlloc(allocator, try published.relativePath(&buffer), 64);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(files[0].bytes, bytes);
}
