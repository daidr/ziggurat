const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const update = @import("root.zig");
pub const Limits = struct {
    max_files: usize = 128,
    max_expanded_bytes: u64 = 512 * 1024 * 1024,
    max_inventory_bytes: usize = 65536,
    /// Keep the authenticated archive as archives/<release>.zip so a later
    /// delta update can rebuild the next archive from it.
    retain_archive: bool = false,
};
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

fn hashFile(file: std.Io.File, expected_bytes: u64, expected_hash: [32]u8) !void {
    if ((try file.stat(zio.io())).size != expected_bytes) return error.SizeMismatch;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(zio.io(), &buffer);
    var discard_buffer: [1024]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);
    _ = try update.stage(.{ .identity = "verified", .target = "verified", .version = .{ .major = 0, .minor = 0, .patch = 0 }, .url = "https://unused.invalid/", .bytes = expected_bytes, .sha256 = expected_hash, .signature = @splat(0) }, &reader.interface, &discard.writer);
}

fn verifyExistingRelease(existing: std.Io.Dir, candidate: std.Io.Dir, names: []const [200]u8, lengths: []const usize) !void {
    var iterator = existing.iterate();
    var count: usize = 0;
    while (try iterator.next(zio.io())) |entry| {
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
        var old = try existing.openFile(zio.io(), name[0..len], .{});
        defer old.close(zio.io());
        var new = try candidate.openFile(zio.io(), name[0..len], .{});
        defer new.close(zio.io());
        const old_stat = try old.stat(zio.io());
        const new_stat = try new.stat(zio.io());
        if (old_stat.kind != .file or old_stat.size != new_stat.size) return error.ReleaseContentMismatch;
        var old_buffer: [16 * 1024]u8 = undefined;
        var new_buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const n = try zio.readAll(new, &new_buffer);
            const m = try zio.readAll(old, &old_buffer);
            if (n != m or !std.mem.eql(u8, old_buffer[0..m], new_buffer[0..n])) return error.ReleaseContentMismatch;
            if (n == 0) break;
        }
    }
}

/// Directory layout is application-owned. No running executable is overwritten.
/// Authenticate the archive, extract a bounded flat release, then atomically
/// publish current.json. Existing releases survive failed publication and rollback.
/// Call on an application-managed worker when disk I/O would block the UI.
pub fn publishZip(allocator: std.mem.Allocator, root: std.Io.Dir, archive: std.Io.File, verified: *const update.Verified, limits: Limits) !Published {
    return publishAuthenticated(allocator, root, archive, verified.manifest, limits);
}

/// Publish an archive whose identity, version, size and digest the caller
/// authenticated by other means, such as an installer that carries its own
/// code signature and an embedded digest. The Ed25519 signature in
/// `manifest` is not checked here; every other rule of `publishZip` applies.
pub fn publishAuthenticated(allocator: std.mem.Allocator, root: std.Io.Dir, archive: std.Io.File, manifest: update.Manifest, limits: Limits) !Published {
    if (limits.max_files == 0 or limits.max_files > 128) return error.InvalidLimits;
    var held = try lock(root);
    defer held.close(zio.io());
    // An older running release cannot overwrite a newer already-published one.
    if (readCurrent(allocator, root, manifest.identity, manifest.target)) |current| {
        if (manifest.version.order(current.version) != .gt) return error.AlreadyPublished;
    } else |err| if (err != error.FileNotFound) return err;

    var releases = try root.createDirPathOpen(zio.io(), "releases", .{ .open_options = .{ .iterate = true, .follow_symlinks = false } });
    defer releases.close(zio.io());
    var staging = try root.createDirPathOpen(zio.io(), "staging", .{ .open_options = .{ .iterate = true, .follow_symlinks = false } });
    defer staging.close(zio.io());
    var random: [16]u8 = undefined;
    zio.random.bytes(&random);
    const nonce = std.fmt.bytesToHex(random, .lower);
    try staging.createDir(zio.io(), &nonce, .default_dir);
    defer staging.deleteTree(zio.io(), &nonce) catch {};
    var temporary = try staging.openDir(zio.io(), &nonce, .{ .iterate = true, .follow_symlinks = false });
    defer temporary.close(zio.io());
    // The caller's download may still be writable. Parse only our private copy
    // whose exact bytes were authenticated while copying into this owned stage.
    var authenticated = try temporary.createFile(zio.io(), "archive.zip", .{ .read = true, .exclusive = true });
    defer authenticated.close(zio.io());
    // A positional reader starts at the beginning whatever the file position.
    var source_buffer: [16 * 1024]u8 = undefined;
    var source = archive.reader(zio.io(), &source_buffer);
    var copy_buffer: [16 * 1024]u8 = undefined;
    var copy = authenticated.writer(zio.io(), &copy_buffer);
    _ = try update.stage(manifest, &source.interface, &copy.interface);
    try copy.interface.flush();
    var destination = try temporary.createDirPathOpen(zio.io(), "payload", .{ .open_options = .{ .iterate = true, .follow_symlinks = false } });
    defer destination.close(zio.io());
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = authenticated.reader(zio.io(), &read_buffer);
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

    const package_bytes = try destination.readFileAlloc(zio.io(), "package.json", allocator, .limited(limits.max_inventory_bytes));
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
        var file = try destination.openFile(zio.io(), payload.path, .{ .mode = .read_write });
        defer file.close(zio.io());
        if ((try file.stat(zio.io())).kind != .file) return error.InvalidPayloadKind;
        try hashFile(file, payload.bytes, digest);
        if (std.mem.eql(u8, payload.path, metadata.executable)) {
            found_executable = true;
            if (builtin.os.tag != .windows) try file.setPermissions(zio.io(), zio.mode(0o755));
        }
        try file.sync(zio.io());
    }
    if (!found_executable) return error.MissingExecutable;
    var result: Published = .{ .version = manifest.version };
    const release_name = try std.fmt.bufPrint(&result.release_storage, "{s}-{s}", .{ manifest.target, version });
    result.release_len = release_name.len;
    @memcpy(result.executable_storage[0..metadata.executable.len], metadata.executable);
    result.executable_len = metadata.executable.len;
    var marker_buffer: [4096]u8 = undefined;
    var atomic = try prepareMarker(allocator, root, &marker_buffer, .{ .identity = manifest.identity, .target = manifest.target, .version = manifest.version, .release = release_name, .executable = metadata.executable });
    defer atomic.deinit();
    // A crash may leave a complete release without publishing its marker. Reuse
    // it only after comparing its exact file set and bytes to this verified stage.
    if (releases.openDir(zio.io(), release_name, .{ .iterate = true, .follow_symlinks = false })) |existing| {
        var retained = existing;
        defer retained.close(zio.io());
        try verifyExistingRelease(retained, destination, names[0..count], lengths[0..count]);
    } else |err| {
        if (err != error.FileNotFound) return err;
        try std.Io.Dir.rename(temporary, "payload", releases, release_name, zio.io());
    }
    if (limits.retain_archive) try retain(root, temporary, release_name, manifest);
    try atomic.renameIntoPlace();
    return result;
}

fn retain(root: std.Io.Dir, temporary: std.Io.Dir, release_name: []const u8, manifest: update.Manifest) !void {
    var archives = try root.createDirPathOpen(zio.io(), "archives", .{ .open_options = .{ .follow_symlinks = false } });
    defer archives.close(zio.io());
    var name_buffer: [264]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.zip", .{release_name});
    if (archives.openFile(zio.io(), name, .{})) |existing| {
        defer existing.close(zio.io());
        // A retry after interruption may find the retained copy; keep it only if exact.
        hashFile(existing, manifest.bytes, manifest.sha256) catch {
            try archives.deleteFile(zio.io(), name);
            try std.Io.Dir.rename(temporary, "archive.zip", archives, name, zio.io());
        };
    } else |err| {
        if (err != error.FileNotFound) return err;
        try std.Io.Dir.rename(temporary, "archive.zip", archives, name, zio.io());
    }
}

pub const MarkerFields = struct { identity: []const u8, target: []const u8, version: update.Version, release: []const u8, executable: []const u8 };

/// Write a synced replacement marker; the caller publishes it with
/// `renameIntoPlace` while holding update.lock.
pub fn prepareMarker(allocator: std.mem.Allocator, root: std.Io.Dir, buffer: []u8, fields: MarkerFields) !zio.AtomicFile {
    const marker = try std.json.Stringify.valueAlloc(allocator, Marker{ .identity = fields.identity, .target = fields.target, .version = fields.version, .release = fields.release, .executable = fields.executable }, .{ .whitespace = .indent_2 });
    defer allocator.free(marker);
    var atomic = try zio.AtomicFile.init(root, "current.json", .{ .write_buffer = buffer });
    errdefer atomic.deinit();
    try atomic.file_writer.interface.writeAll(marker);
    try atomic.flush();
    try atomic.file_writer.file.sync(zio.io());
    return atomic;
}

/// Take the publication lock shared with `publishZip`.
pub fn lock(root: std.Io.Dir) !std.Io.File {
    return root.createFile(zio.io(), "update.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| {
        if (err == error.WouldBlock) return error.UpdateInProgress;
        return err;
    };
}

/// Check every payload file of a published release against its package.json.
pub fn verifyRelease(allocator: std.mem.Allocator, release: std.Io.Dir, identity: []const u8, target: []const u8, version: update.Version, limits: Limits) ![]u8 {
    const package_bytes = try release.readFileAlloc(zio.io(), "package.json", allocator, .limited(limits.max_inventory_bytes));
    defer allocator.free(package_bytes);
    const package = std.json.parseFromSlice(Package, allocator, package_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidInventory;
    };
    defer package.deinit();
    const metadata = package.value;
    var version_buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&version_buffer, "{d}.{d}.{d}.{d}", .{ version.major, version.minor, version.patch, version.revision });
    if (metadata.schema_version != 1 or !std.mem.eql(u8, metadata.identity, identity) or !std.mem.eql(u8, metadata.target, target) or !std.mem.eql(u8, metadata.version, text)) return error.PackageIdentityMismatch;
    try validateFilename(metadata.executable);
    var found_executable = false;
    for (metadata.files) |payload| {
        try validateFilename(payload.path);
        if (payload.sha256.len != 64) return error.InvalidEncoding;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, payload.sha256) catch return error.InvalidEncoding;
        var file = try release.openFile(zio.io(), payload.path, .{});
        defer file.close(zio.io());
        try hashFile(file, payload.bytes, digest);
        if (std.mem.eql(u8, payload.path, metadata.executable)) found_executable = true;
    }
    if (!found_executable) return error.MissingExecutable;
    return allocator.dupe(u8, metadata.executable);
}

/// Resolve only inside the managed release namespace. The application owns and
/// protects this root; this marker is not an authentication boundary by itself.
pub fn readCurrent(allocator: std.mem.Allocator, root: std.Io.Dir, identity: []const u8, target: []const u8) !Published {
    const bytes = try root.readFileAlloc(zio.io(), "current.json", allocator, .limited(4096));
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
