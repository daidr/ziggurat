const std = @import("std");
const update = @import("root.zig");
const publication = @import("publication.zig");

/// Published versions for `target` under root/releases, ascending. Names
/// that do not parse as `<target>-<a.b.c.d>` are ignored. Caller frees.
pub fn list(allocator: std.mem.Allocator, root: std.fs.Dir, target: []const u8) ![]update.Version {
    var versions: std.ArrayList(update.Version) = .empty;
    errdefer versions.deinit(allocator);
    var releases = root.openDir("releases", .{ .iterate = true, .no_follow = true }) catch |err| {
        if (err == error.FileNotFound) return versions.toOwnedSlice(allocator);
        return err;
    };
    defer releases.close();
    var iterator = releases.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len <= target.len + 1 or !std.mem.startsWith(u8, entry.name, target) or entry.name[target.len] != '-') continue;
        const version = parseVersion(entry.name[target.len + 1 ..]) catch continue;
        try versions.append(allocator, version);
    }
    std.mem.sort(update.Version, versions.items, {}, struct {
        fn lessThan(_: void, a: update.Version, b: update.Version) bool {
            return a.order(b) == .lt;
        }
    }.lessThan);
    return versions.toOwnedSlice(allocator);
}

pub fn parseVersion(text: []const u8) !update.Version {
    var parts = std.mem.splitScalar(u8, text, '.');
    var result: update.Version = undefined;
    inline for (.{ "major", "minor", "patch", "revision" }) |field| {
        const part = parts.next() orelse return error.InvalidVersion;
        if (part.len == 0 or part.len > 5) return error.InvalidVersion;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
        @field(result, field) = std.fmt.parseInt(u16, part, 10) catch return error.InvalidVersion;
    }
    if (parts.next() != null) return error.InvalidVersion;
    return result;
}

fn releaseName(buffer: []u8, target: []const u8, version: update.Version) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{d}.{d}.{d}.{d}", .{ target, version.major, version.minor, version.patch, version.revision });
}

/// Point current.json at a retained release after re-checking every file of
/// that release against its inventory. Rolling back is an explicit host
/// decision: the update check that follows will offer newer versions again
/// unless the host skips them.
pub fn rollback(allocator: std.mem.Allocator, root: std.fs.Dir, identity: []const u8, target: []const u8, version: update.Version) !publication.Published {
    var held = try publication.lock(root);
    defer held.close();
    const current = try publication.readCurrent(allocator, root, identity, target);
    if (current.version.order(version) == .eq) return error.AlreadyCurrent;
    var name_buffer: [256]u8 = undefined;
    const name = try releaseName(&name_buffer, target, version);
    var path_buffer: [272]u8 = undefined;
    var release = root.openDir(try std.fmt.bufPrint(&path_buffer, "releases/{s}", .{name}), .{ .no_follow = true }) catch |err| {
        if (err == error.FileNotFound) return error.ReleaseNotRetained;
        return err;
    };
    defer release.close();
    const executable = try publication.verifyRelease(allocator, release, identity, target, version, .{});
    defer allocator.free(executable);
    var marker_buffer: [4096]u8 = undefined;
    var atomic = try publication.prepareMarker(allocator, root, &marker_buffer, .{ .identity = identity, .target = target, .version = version, .release = name, .executable = executable });
    defer atomic.deinit();
    try atomic.renameIntoPlace();
    var result: publication.Published = .{ .version = version };
    @memcpy(result.release_storage[0..name.len], name);
    result.release_len = name.len;
    @memcpy(result.executable_storage[0..executable.len], executable);
    result.executable_len = executable.len;
    return result;
}

/// Delete releases (and their retained archives) older than the newest
/// `keep` versions. The current release is always kept, and so is any release
/// newer than it. Returns the number of releases removed. Do not prune while
/// an older release may still be running.
pub fn prune(allocator: std.mem.Allocator, root: std.fs.Dir, identity: []const u8, target: []const u8, keep: usize) !usize {
    var held = try publication.lock(root);
    defer held.close();
    const current = try publication.readCurrent(allocator, root, identity, target);
    const versions = try list(allocator, root, target);
    defer allocator.free(versions);
    var removed: usize = 0;
    const retained_from = versions.len -| keep;
    var releases = try root.openDir("releases", .{ .no_follow = true });
    defer releases.close();
    var archives: ?std.fs.Dir = root.openDir("archives", .{ .no_follow = true }) catch null;
    defer if (archives) |*dir| dir.close();
    for (versions[0..retained_from]) |version| {
        if (version.order(current.version) != .lt) continue;
        var name_buffer: [256]u8 = undefined;
        const name = try releaseName(&name_buffer, target, version);
        try releases.deleteTree(name);
        if (archives) |dir| {
            var archive_buffer: [264]u8 = undefined;
            dir.deleteFile(try std.fmt.bufPrint(&archive_buffer, "{s}.zip", .{name})) catch |err| if (err != error.FileNotFound) return err;
        }
        removed += 1;
    }
    return removed;
}

pub const Retained = struct {
    file: std.fs.File,
    sha256: [32]u8,
    version: update.Version,
};

/// Open the retained archive of the current release and hash it, for a delta
/// check. Returns null when the release was published without retention.
pub fn currentArchive(allocator: std.mem.Allocator, root: std.fs.Dir, identity: []const u8, target: []const u8) !?Retained {
    const current = try publication.readCurrent(allocator, root, identity, target);
    var path_buffer: [300]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "archives/{s}.zip", .{current.release_storage[0..current.release_len]});
    const file = root.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    errdefer file.close();
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.pread(&buffer, offset);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        offset += n;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .file = file, .sha256 = digest, .version = current.version };
}
