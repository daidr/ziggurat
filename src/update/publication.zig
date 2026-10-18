const std = @import("std");
const builtin = @import("builtin");
const update = @import("root.zig");
pub const Limits = struct { max_files: usize = 128, max_expanded_bytes: u64 = 512 * 1024 * 1024, max_inventory_bytes: usize = 65536 };
const Payload = struct { path: []const u8, bytes: u64, sha256: []const u8 };
const Package = struct { schema_version: u16, identity: []const u8, version: []const u8, target: []const u8, executable: []const u8, files: []const Payload };
const Marker = struct { format: u16 = 1, identity: []const u8, target: []const u8, version: update.Version, release: []const u8, executable: []const u8 };
pub const Published = struct {
    release_storage: [256]u8 = undefined,
    release_len: usize = 0,
    executable_storage: [200]u8 = undefined,
    executable_len: usize = 0,
    version: update.Version,
    pub fn relativePath(self: *const Published, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "releases/{s}/{s}", .{ self.release_storage[0..self.release_len], self.executable_storage[0..self.executable_len] });
    }
};

/// Flat release payloads avoid platform separator, device-name and case aliases.
pub fn validateFilename(name: []const u8) !void {
    if (name.len == 0 or name.len > 200 or name[0] == '.' or name[name.len - 1] == '.') return error.InvalidPayloadName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidPayloadName;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidPayloadName;
    }
}

fn hashFile(file: std.fs.File, expected_bytes: u64, expected_hash: [32]u8) !void {
    if ((try file.stat()).size != expected_bytes) return error.SizeMismatch;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(&buffer);
    var discard_buffer: [1024]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);
    _ = try update.stage(.{ .identity = "verified", .target = "verified", .version = .{ .major = 0, .minor = 0, .patch = 0 }, .url = "https://unused.invalid/", .bytes = expected_bytes, .sha256 = expected_hash, .signature = @splat(0) }, &reader.interface, &discard.writer);
}

fn verifyExistingRelease(existing: std.fs.Dir, candidate: std.fs.Dir, names: []const [200]u8, lengths: []const usize) !void {
    var iterator = existing.iterate();
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) return error.ReleaseContentMismatch;
        var found = false;
        for (names, lengths) |name, len| if (std.mem.eql(u8, entry.name, name[0..len])) {
            found = true;
            break;
        };
        if (!found) return error.ReleaseContentMismatch;
        count += 1;
    }
    if (count != names.len) return error.ReleaseContentMismatch;
    for (names, lengths) |name, len| {
        var old = try existing.openFile(name[0..len], .{});
        defer old.close();
        var new = try candidate.openFile(name[0..len], .{});
        defer new.close();
        const old_stat = try old.stat();
        const new_stat = try new.stat();
        if (old_stat.kind != .file or old_stat.size != new_stat.size) return error.ReleaseContentMismatch;
        var old_buffer: [16 * 1024]u8 = undefined;
        var new_buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const n = try new.readAll(&new_buffer);
            const m = try old.readAll(&old_buffer);
            if (n != m or !std.mem.eql(u8, old_buffer[0..m], new_buffer[0..n])) return error.ReleaseContentMismatch;
            if (n == 0) break;
        }
    }
}

/// Directory layout is application-owned. No running executable is overwritten.
/// Authenticate the archive, extract a bounded flat release, then atomically
/// publish current.json. Existing releases survive failed publication and rollback.
/// Call on an application-managed worker when disk I/O would block the UI.
pub fn publishZip(allocator: std.mem.Allocator, root: std.fs.Dir, archive: std.fs.File, verified: *const update.Verified, limits: Limits) !Published {
    if (limits.max_files == 0 or limits.max_files > 128) return error.InvalidLimits;
    const manifest = verified.manifest;
    var lock = root.createFile("update.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| {
        if (err == error.WouldBlock) return error.UpdateInProgress;
        return err;
    };
    defer lock.close();
    // An older running release cannot overwrite a newer already-published one.
    if (readCurrent(allocator, root, manifest.identity, manifest.target)) |current| {
        if (manifest.version.order(current.version) != .gt) return error.AlreadyPublished;
    } else |err| if (err != error.FileNotFound) return err;

    var releases = try root.makeOpenPath("releases", .{ .iterate = true, .no_follow = true });
    defer releases.close();
    var staging = try root.makeOpenPath("staging", .{ .iterate = true, .no_follow = true });
    defer staging.close();
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const nonce = std.fmt.bytesToHex(random, .lower);
    try staging.makeDir(&nonce);
    defer staging.deleteTree(&nonce) catch {};
    var temporary = try staging.openDir(&nonce, .{ .iterate = true, .no_follow = true });
    defer temporary.close();
    // The caller's download may still be writable. Parse only our private copy
    // whose exact bytes were authenticated while copying into this owned stage.
    var authenticated = try temporary.createFile("archive.zip", .{ .read = true, .exclusive = true });
    defer authenticated.close();
    try archive.seekTo(0);
    var source_buffer: [16 * 1024]u8 = undefined;
    var source = archive.reader(&source_buffer);
    var copy_buffer: [16 * 1024]u8 = undefined;
    var copy = authenticated.writer(&copy_buffer);
    _ = try update.stage(manifest, &source.interface, &copy.interface);
    try copy.interface.flush();
    var destination = try temporary.makeOpenPath("payload", .{ .iterate = true, .no_follow = true });
    defer destination.close();
    var read_buffer: [16 * 1024]u8 = undefined;
    try authenticated.seekTo(0);
    var reader = authenticated.reader(&read_buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    if (iterator.cd_record_count == 0 or iterator.cd_record_count > limits.max_files) return error.TooManyPayloadFiles;
    var names: [128][200]u8 = undefined;
    var lengths: [128]usize = undefined;
    var count: usize = 0;
    var expanded: u64 = 0;
    while (try iterator.next()) |entry| {
        if (entry.filename_len > 200 or entry.filename_len == 0) return error.InvalidPayloadName;
        if (entry.uncompressed_size > limits.max_expanded_bytes - expanded) return error.ExpandedSizeLimit;
        expanded += entry.uncompressed_size;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename = names[count][0..entry.filename_len];
        try reader.interface.readSliceAll(filename);
        try validateFilename(filename);
        for (names[0..count], lengths[0..count]) |previous, len| if (std.ascii.eqlIgnoreCase(previous[0..len], filename)) return error.DuplicatePayloadName;
        lengths[count] = filename.len;
        count += 1;
        if (std.mem.eql(u8, filename, "package.json") and entry.uncompressed_size > limits.max_inventory_bytes) return error.InventoryTooLarge;
    }
    // No payload is extracted before all central-directory names/sizes pass.
    iterator = try std.zip.Iterator.init(&reader);
    var filename_buffer: [200]u8 = undefined;
    while (try iterator.next()) |entry| try entry.extract(&reader, .{}, &filename_buffer, destination);

    const package_bytes = try destination.readFileAlloc(allocator, "package.json", limits.max_inventory_bytes);
    defer allocator.free(package_bytes);
    const package = try std.json.parseFromSlice(Package, allocator, package_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer package.deinit();
    const metadata = package.value;
    var version_buffer: [32]u8 = undefined;
    const version = try std.fmt.bufPrint(&version_buffer, "{d}.{d}.{d}.{d}", .{ manifest.version.major, manifest.version.minor, manifest.version.patch, manifest.version.revision });
    if (metadata.schema_version != 1 or !std.mem.eql(u8, metadata.identity, manifest.identity) or !std.mem.eql(u8, metadata.target, manifest.target) or !std.mem.eql(u8, metadata.version, version)) return error.PackageIdentityMismatch;
    try validateFilename(metadata.executable);
    if (metadata.files.len + 1 != count) return error.InventoryMismatch;
    var found_executable = false;
    for (metadata.files, 0..) |payload, payload_index| {
        try validateFilename(payload.path);
        if (std.ascii.eqlIgnoreCase(payload.path, "package.json")) return error.InventoryMismatch;
        for (metadata.files[0..payload_index]) |previous| if (std.ascii.eqlIgnoreCase(previous.path, payload.path)) return error.DuplicatePayloadName;
        var found = false;
        for (names[0..count], lengths[0..count]) |name, len| if (std.mem.eql(u8, name[0..len], payload.path)) {
            found = true;
            break;
        };
        if (!found or payload.sha256.len != 64) return error.InventoryMismatch;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, payload.sha256) catch return error.InvalidEncoding;
        var file = try destination.openFile(payload.path, .{ .mode = .read_write });
        defer file.close();
        if ((try file.stat()).kind != .file) return error.InvalidPayloadKind;
        try hashFile(file, payload.bytes, digest);
        if (std.mem.eql(u8, payload.path, metadata.executable)) {
            found_executable = true;
            if (builtin.os.tag != .windows) try file.chmod(0o755);
        }
        try file.sync();
    }
    if (!found_executable) return error.MissingExecutable;
    var result: Published = .{ .version = manifest.version };
    const release_name = try std.fmt.bufPrint(&result.release_storage, "{s}-{s}", .{ manifest.target, version });
    result.release_len = release_name.len;
    @memcpy(result.executable_storage[0..metadata.executable.len], metadata.executable);
    result.executable_len = metadata.executable.len;
    const marker = try std.json.Stringify.valueAlloc(allocator, Marker{ .identity = manifest.identity, .target = manifest.target, .version = manifest.version, .release = release_name, .executable = metadata.executable }, .{ .whitespace = .indent_2 });
    defer allocator.free(marker);
    var marker_buffer: [4096]u8 = undefined;
    var atomic = try root.atomicFile("current.json", .{ .write_buffer = &marker_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(marker);
    try atomic.flush();
    try atomic.file_writer.file.sync();
    // A crash may leave a complete release without publishing its marker. Reuse
    // it only after comparing its exact file set and bytes to this verified stage.
    if (releases.openDir(release_name, .{ .iterate = true, .no_follow = true })) |existing| {
        var retained = existing;
        defer retained.close();
        try verifyExistingRelease(retained, destination, names[0..count], lengths[0..count]);
    } else |err| {
        if (err != error.FileNotFound) return err;
        try std.fs.rename(temporary, "payload", releases, release_name);
    }
    try atomic.renameIntoPlace();
    return result;
}

/// Resolve only inside the managed release namespace. The application owns and
/// protects this root; this marker is not an authentication boundary by itself.
pub fn readCurrent(allocator: std.mem.Allocator, root: std.fs.Dir, identity: []const u8, target: []const u8) !Published {
    const bytes = try root.readFileAlloc(allocator, "current.json", 4096);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Marker, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const marker = parsed.value;
    if (marker.format != 1 or !std.mem.eql(u8, marker.identity, identity) or !std.mem.eql(u8, marker.target, target)) return error.PackageIdentityMismatch;
    try validateFilename(marker.release);
    try validateFilename(marker.executable);
    var result: Published = .{ .version = marker.version };
    const release_name = try std.fmt.bufPrint(&result.release_storage, "{s}-{d}.{d}.{d}.{d}", .{ target, marker.version.major, marker.version.minor, marker.version.patch, marker.version.revision });
    if (!std.mem.eql(u8, marker.release, release_name)) return error.InvalidReleasePath;
    result.release_len = release_name.len;
    result.executable_len = marker.executable.len;
    @memcpy(result.executable_storage[0..result.executable_len], marker.executable);
    return result;
}

test "portable payload names reject traversal aliases and reserved device names" {
    for ([_][]const u8{ "", ".", "..", "../app", "sub/app", "sub\\app", "C:app", "file.", "file ", "CON.exe", "NUL", "com1.bin", "x\x00y" }) |name| try std.testing.expectError(error.InvalidPayloadName, validateFilename(name));
    try validateFilename("WebView2-SDK-LICENSE.txt");
    try validateFilename("counter.exe");
    try validateFilename("package.json");
}
