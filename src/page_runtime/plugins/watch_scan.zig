//! What a watch saw of its directory or file, and the events that say what
//! is different. The system watcher reports only which directories changed;
//! the scan lists or stats them again and compares what it finds with what it
//! saw. Only the watch's worker uses a scan.
const std = @import("std");
const builtin = @import("builtin");
const Service = @import("watch_service.zig").Service;

const is_windows = builtin.os.tag == .windows;

pub const Kind = enum(u8) { file, directory, symlink, other };

/// A file's identity: a file system that reuses a freed inode for the next
/// file may give a removed directory's to a new symlink, so the kind counts.
pub const Id = struct {
    device: u64,
    inode: u64,
    kind: Kind,
};

pub const Entry = struct {
    id: Id,
    size: u64,
    mtime: i128,

    pub fn isDir(self: Entry) bool {
        return self.id.kind == .directory;
    }
};

/// Asked about every file and directory a scan finds, by its path relative
/// to the root, separated by slashes. An ignored directory is never listed.
/// It runs on the watch's worker.
pub const Ignore = struct {
    context: *anyopaque,
    ignore: *const fn (*anyopaque, path: []const u8, is_dir: bool) bool,
};

pub const Error = error{ Limit, PathEncoding, Gone, OutOfMemory, Io };

/// The events of one update; the arena holds their strings.
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    events: []Service.Event,

    pub fn deinit(self: *Batch) void {
        self.arena.deinit();
    }
};

pub const Scan = struct {
    allocator: std.mem.Allocator,
    /// The watched directory, or the directory of the watched file, and its
    /// absolute path.
    dir: std.fs.Dir,
    path: []const u8,
    /// The watched file's name in `dir`; null for a directory.
    file: ?[]const u8,
    recursive: bool,
    max_entries: usize,
    ignore: ?Ignore,
    /// What is watched, relative to the root, for `ignore`; "." for the root.
    prefix: []const u8,
    /// Keys are owned: "." and slash-separated paths beneath it.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// What an update looked at, as it was before; null when it did not exist.
    before: std.StringHashMapUnmanaged(?Entry) = .empty,
    starting: bool = false,
    /// What `dir` was when the scan started.
    identity: ?Id = null,

    pub fn deinit(self: *Scan) void {
        self.clearBefore();
        self.before.deinit(self.allocator);
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.entries.deinit(self.allocator);
    }

    /// Records what is there; nothing is reported for it.
    pub fn start(self: *Scan) Error!void {
        self.starting = true;
        defer self.starting = false;
        self.identity = (statSelf(self.dir) catch return error.Io).id;
        if (self.file) |name| {
            const entry = statAt(self.dir, name) catch |err| return mapStat(err);
            if (entry.id.kind != .file) return error.Io;
            return self.set(".", entry);
        }
        try self.set(".", statSelf(self.dir) catch return error.Io);
        try self.list(".", true);
    }

    /// Whether the directory went away or was replaced. An open directory
    /// removed lists as empty, and the system may say it is gone only once
    /// the scan lets go of it.
    fn vanished(self: *Scan) bool {
        const now = lstatAbsolute(self.path) catch return true;
        return !std.meta.eql(now.id, self.identity.?);
    }

    /// The directory at `absolute`, which `root_path` begins, changed.
    pub fn changed(self: *Scan, root_path: []const u8, absolute: []const u8) Error!void {
        if (self.file != null) return self.statFile();
        const relative = relativeTo(root_path, absolute) orelse return;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (relative.len > buffer.len) return;
        const key = toSlashes(buffer[0..relative.len], relative);
        const known = self.entries.get(key) orelse return;
        if (!known.isDir() or !self.descends(key)) return;
        try self.list(key, false);
    }

    /// The system lost changes: look at everything again.
    pub fn rescan(self: *Scan) Error!void {
        if (self.file != null) return self.statFile();
        try self.list(".", true);
    }

    /// The events since the last call: what differs from what was seen.
    pub fn events(self: *Scan) Error!Batch {
        var batch: Batch = .{ .arena = .init(self.allocator), .events = &.{} };
        errdefer batch.deinit();
        batch.events = try diff(batch.arena.allocator(), &self.before, &self.entries);
        if (self.file != null) {
            const a = self.before.get(".");
            const b = self.entries.get(".");
            if (a != null and a.? != null and b != null and a.?.?.id.kind == .file and b.?.id.kind == .file and !std.meta.eql(a.?.?.id, b.?.id)) {
                // A file replaced, as editors save, is written.
                const one = try batch.arena.allocator().alloc(Service.Event, 1);
                one[0] = .{ .op = .write, .path = ".", .oldPath = null, .isDir = false };
                batch.events = one;
            }
        }
        self.clearBefore();
        for (batch.events) |event| {
            if (!std.unicode.utf8ValidateSlice(event.path)) return error.PathEncoding;
            if (event.oldPath) |old| if (!std.unicode.utf8ValidateSlice(old)) return error.PathEncoding;
        }
        return batch;
    }

    /// The last event of a watch whose directory went away: none for a
    /// watched file that was already gone. What changed before is dropped.
    pub fn gone(self: *Scan) Error!Batch {
        self.clearBefore();
        var batch: Batch = .{ .arena = .init(self.allocator), .events = &.{} };
        const last = self.entries.get(".") orelse return batch;
        const one = batch.arena.allocator().alloc(Service.Event, 1) catch {
            batch.deinit();
            return error.OutOfMemory;
        };
        one[0] = .{ .op = .remove, .path = ".", .oldPath = null, .isDir = last.isDir() };
        batch.events = one;
        return batch;
    }

    fn statFile(self: *Scan) Error!void {
        if (self.vanished()) return error.Gone;
        const entry: ?Entry = statAt(self.dir, self.file.?) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.Io,
        };
        const known = self.entries.get(".");
        if (entry) |now| {
            // A watched file is watched only while it is a file.
            if (now.id.kind != .file) {
                if (known != null) self.removeTree(".");
                return;
            }
            if (known) |was| if (std.meta.eql(was, now)) return;
            try self.touch(".");
            return self.set(".", now);
        }
        if (known != null) self.removeTree(".");
    }

    fn descends(self: *const Scan, path: []const u8) bool {
        return self.recursive or std.mem.eql(u8, path, ".");
    }

    /// Lists directory `path` again: what appeared or was replaced in it is
    /// visited, what is gone removed, and files stat'ed again. With `deep`
    /// the directories in it are listed too.
    fn list(self: *Scan, path: []const u8, deep: bool) Error!void {
        if (std.mem.eql(u8, path, ".") and self.vanished()) return error.Gone;
        var directory = self.openDir(path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                if (std.mem.eql(u8, path, ".")) return error.Gone;
                // Its parent's listing says what became of it.
                return;
            },
            else => return if (std.mem.eql(u8, path, ".")) error.Io else {},
        };
        defer if (!std.mem.eql(u8, path, ".")) directory.close();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var keys = seen.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            seen.deinit(self.allocator);
        }
        var children: std.ArrayList([]u8) = .empty;
        defer {
            for (children.items) |child| self.allocator.free(child);
            children.deinit(self.allocator);
        }
        var iterator = directory.iterate();
        while (true) {
            const item = (iterator.next() catch return error.Io) orelse break;
            const child = try self.join(path, item.name);
            defer self.allocator.free(child);
            const entry = statAt(directory, item.name) catch |err| switch (err) {
                // Gone while it looked: the next change lists it again.
                error.FileNotFound => continue,
                else => continue,
            };
            if (self.ignored(child, entry.isDir())) continue;
            try seen.put(self.allocator, try self.allocator.dupe(u8, item.name), {});
            if (self.entries.get(child)) |known| {
                if (!std.meta.eql(known.id, entry.id)) {
                    self.removeTree(child);
                    try self.visit(child, entry);
                } else if (!entry.isDir()) {
                    if (known.size != entry.size or known.mtime != entry.mtime) {
                        try self.touch(child);
                        try self.set(child, entry);
                    }
                } else if (deep and self.descends(child)) {
                    try children.append(self.allocator, try self.allocator.dupe(u8, child));
                }
            } else try self.visit(child, entry);
        }
        // What it knew in the directory and no longer found is gone.
        var missing: std.ArrayList([]u8) = .empty;
        defer {
            for (missing.items) |child| self.allocator.free(child);
            missing.deinit(self.allocator);
        }
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| {
            if (std.mem.eql(u8, key.*, ".")) continue;
            const parent = parentOf(key.*);
            if (!std.mem.eql(u8, parent, path)) continue;
            if (seen.contains(baseOf(key.*))) continue;
            try missing.append(self.allocator, try self.allocator.dupe(u8, key.*));
        }
        for (missing.items) |child| self.removeTree(child);
        for (children.items) |child| try self.list(child, true);
    }

    /// Records `path`, which it did not know, and what is beneath it.
    fn visit(self: *Scan, path: []const u8, entry: Entry) Error!void {
        try self.touch(path);
        try self.set(path, entry);
        if (entry.isDir() and self.descends(path)) try self.list(path, true);
    }

    /// Forgets `path` and what is beneath it.
    fn removeTree(self: *Scan, path: []const u8) void {
        const all = std.mem.eql(u8, path, ".");
        while (true) {
            var found: ?[]const u8 = null;
            var keys = self.entries.keyIterator();
            while (keys.next()) |key| {
                if (all or std.mem.eql(u8, key.*, path) or (key.len > path.len and std.mem.startsWith(u8, key.*, path) and key.*[path.len] == '/')) {
                    found = key.*;
                    break;
                }
            }
            const key = found orelse return;
            // Touching only allocates the before-copy; without it the event
            // is lost, never the snapshot's consistency.
            self.touch(key) catch {};
            const removed = self.entries.fetchRemove(key).?;
            self.allocator.free(removed.key);
        }
    }

    fn touch(self: *Scan, path: []const u8) Error!void {
        if (self.starting or self.before.contains(path)) return;
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.before.put(self.allocator, key, self.entries.get(path));
    }

    fn set(self: *Scan, path: []const u8, entry: Entry) Error!void {
        if (self.entries.getPtr(path)) |slot| {
            slot.* = entry;
            return;
        }
        if (self.entries.count() >= self.max_entries) return error.Limit;
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.entries.put(self.allocator, key, entry);
    }

    fn clearBefore(self: *Scan) void {
        var keys = self.before.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.before.clearRetainingCapacity();
    }

    fn ignored(self: *Scan, path: []const u8, is_dir: bool) bool {
        const ignore = self.ignore orelse return false;
        if (std.mem.eql(u8, self.prefix, ".")) return ignore.ignore(ignore.context, path, is_dir);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.prefix, path }) catch return false;
        return ignore.ignore(ignore.context, full, is_dir);
    }

    fn join(self: *Scan, parent: []const u8, name: []const u8) Error![]u8 {
        if (std.mem.eql(u8, parent, ".")) return self.allocator.dupe(u8, name);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, name });
    }

    fn openDir(self: *Scan, path: []const u8) !std.fs.Dir {
        if (std.mem.eql(u8, path, ".")) return self.dir;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len > buffer.len) return error.NameTooLong;
        const native = buffer[0..path.len];
        @memcpy(native, path);
        if (is_windows) std.mem.replaceScalar(u8, native, '/', '\\');
        return self.dir.openDir(native, .{ .iterate = true, .no_follow = true });
    }
};

fn mapStat(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.Gone,
        else => error.Io,
    };
}

/// `absolute` relative to `root`, or null when it is not beneath it.
fn relativeTo(root: []const u8, absolute: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, absolute, root)) return null;
    if (absolute.len == root.len) return ".";
    const rest = absolute[root.len..];
    if (rest[0] != '/' and rest[0] != '\\') return null;
    if (rest.len == 1) return ".";
    return rest[1..];
}

fn toSlashes(buffer: []u8, path: []const u8) []const u8 {
    @memcpy(buffer, path);
    if (is_windows) std.mem.replaceScalar(u8, buffer, '\\', '/');
    return buffer;
}

fn parentOf(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    return path[0..at];
}

fn baseOf(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[at + 1 ..];
}

/// Stats `path` without following a symlink.
pub fn lstatAbsolute(path: []const u8) !Entry {
    const parent = std.fs.path.dirname(path) orelse {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return statSelf(dir);
    };
    var dir = try std.fs.openDirAbsolute(parent, .{});
    defer dir.close();
    return statAt(dir, std.fs.path.basename(path));
}

/// Stats `name` in `dir` without following a symlink.
pub fn statAt(dir: std.fs.Dir, name: []const u8) !Entry {
    if (is_windows) {
        const w = std.os.windows;
        const path = try w.sliceToPrefixedFileW(dir.fd, name);
        const handle = try w.OpenFile(path.span(), .{
            .dir = dir.fd,
            .access_mask = w.FILE_READ_ATTRIBUTES | w.SYNCHRONIZE,
            .creation = w.FILE_OPEN,
            .filter = .any,
            .follow_symlinks = false,
        });
        const file: std.fs.File = .{ .handle = handle };
        defer file.close();
        return fromStat(try file.stat());
    }
    const linux = std.os.linux;
    const path = try std.posix.toPosixPath(name);
    var stx = std.mem.zeroes(linux.Statx);
    const mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO | linux.STATX_SIZE | linux.STATX_MTIME;
    return switch (linux.E.init(linux.statx(dir.fd, &path, linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT, mask, &stx))) {
        .SUCCESS => fromStatx(stx),
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// Stats the directory `dir` itself.
pub fn statSelf(dir: std.fs.Dir) !Entry {
    if (is_windows) {
        const file: std.fs.File = .{ .handle = dir.fd };
        return fromStat(try file.stat());
    }
    const linux = std.os.linux;
    var stx = std.mem.zeroes(linux.Statx);
    const mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO | linux.STATX_SIZE | linux.STATX_MTIME;
    return switch (linux.E.init(linux.statx(dir.fd, "", linux.AT.EMPTY_PATH, mask, &stx))) {
        .SUCCESS => fromStatx(stx),
        else => error.Unexpected,
    };
}

fn fromStatx(stx: std.os.linux.Statx) Entry {
    const S = std.os.linux.S;
    const kind: Kind = switch (stx.mode & S.IFMT) {
        S.IFREG => .file,
        S.IFDIR => .directory,
        S.IFLNK => .symlink,
        else => .other,
    };
    return .{
        .id = .{ .device = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .inode = stx.ino, .kind = kind },
        .size = stx.size,
        .mtime = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
    };
}

fn fromStat(stat: std.fs.File.Stat) Entry {
    const kind: Kind = switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
    return .{ .id = .{ .device = 0, .inode = @intCast(stat.inode), .kind = kind }, .size = stat.size, .mtime = stat.mtime };
}

const Group = struct {
    path: []const u8,
    events: []Service.Event,

    fn less(_: void, a: Group, b: Group) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

const Seen = struct { path: []const u8, count: u32 };

/// Turns what an update looked at (`before`, as it was) and what is now
/// (`entries`) into events, grouped and ordered by path. An entry whose
/// identity moved to another path is a rename when nothing else had or has
/// that identity; entries moved with a directory renamed above them are
/// said by the directory's rename.
pub fn diff(arena: std.mem.Allocator, before: *const std.StringHashMapUnmanaged(?Entry), entries: *const std.StringHashMapUnmanaged(Entry)) ![]Service.Event {
    var removed: std.StringHashMapUnmanaged(Entry) = .empty;
    var created: std.StringHashMapUnmanaged(Entry) = .empty;
    var iterator = before.iterator();
    while (iterator.next()) |item| {
        const was = item.value_ptr.*;
        const now = entries.get(item.key_ptr.*);
        if (was != null and (now == null or !std.meta.eql(was.?.id, now.?.id))) try removed.put(arena, item.key_ptr.*, was.?);
        if (now != null and (was == null or !std.meta.eql(was.?.id, now.?.id))) try created.put(arena, item.key_ptr.*, now.?);
    }
    // Identities counted over what the update looked at, before and after.
    var ids_before: std.AutoHashMapUnmanaged(Id, Seen) = .empty;
    var ids_after: std.AutoHashMapUnmanaged(Id, Seen) = .empty;
    if (removed.count() > 0 and created.count() > 0) {
        iterator = before.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.*) |was| try count(arena, &ids_before, was.id, item.key_ptr.*);
            if (entries.get(item.key_ptr.*)) |now| try count(arena, &ids_after, now.id, item.key_ptr.*);
        }
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var removed_keys = removed.keyIterator();
    while (removed_keys.next()) |key| try keys.append(arena, key.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var groups: std.ArrayList(Group) = .empty;
    var paired: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (keys.items) |old| {
        const a = removed.get(old).?;
        const match = pair(&ids_before, &ids_after, a.id) orelse continue;
        if (!created.contains(match)) continue;
        // A replacement is a removal and a creation even if the old name
        // survives elsewhere.
        if (entries.contains(old)) continue;
        if (before.get(match)) |was| if (was != null) continue;
        // Moved with a directory renamed above it, which says it all.
        var descendant = false;
        var parent = parentOf(old);
        while (!std.mem.eql(u8, parent, ".")) : (parent = parentOf(parent)) {
            if (paired.get(parent)) |destination| {
                if (match.len == destination.len + (old.len - parent.len) and std.mem.startsWith(u8, match, destination) and std.mem.eql(u8, match[destination.len..], old[parent.len..])) {
                    descendant = true;
                    break;
                }
            }
        }
        try paired.put(arena, old, match);
        _ = removed.remove(old);
        const b = created.get(match).?;
        _ = created.remove(match);
        var events: std.ArrayList(Service.Event) = .empty;
        if (!descendant) try events.append(arena, .{ .op = .rename, .oldPath = old, .path = match, .isDir = a.isDir() });
        if (!b.isDir() and (a.size != b.size or a.mtime != b.mtime)) try events.append(arena, .{ .op = .write, .path = match, .oldPath = null, .isDir = false });
        try groups.append(arena, .{ .path = match, .events = events.items });
    }
    iterator = before.iterator();
    while (iterator.next()) |item| {
        const path = item.key_ptr.*;
        var events: std.ArrayList(Service.Event) = .empty;
        if (removed.get(path)) |a| try events.append(arena, .{ .op = .remove, .path = path, .oldPath = null, .isDir = a.isDir() });
        if (created.get(path)) |b| try events.append(arena, .{ .op = .create, .path = path, .oldPath = null, .isDir = b.isDir() });
        if (item.value_ptr.*) |was| if (entries.get(path)) |now| {
            if (!now.isDir() and std.meta.eql(was.id, now.id) and (was.size != now.size or was.mtime != now.mtime)) {
                try events.append(arena, .{ .op = .write, .path = path, .oldPath = null, .isDir = false });
            }
        };
        if (events.items.len > 0) try groups.append(arena, .{ .path = path, .events = events.items });
    }
    std.mem.sort(Group, groups.items, {}, Group.less);
    var result: std.ArrayList(Service.Event) = .empty;
    for (groups.items) |group| {
        for (group.events) |event| {
            var copy = event;
            copy.path = try arena.dupe(u8, event.path);
            if (event.oldPath) |old| copy.oldPath = try arena.dupe(u8, old);
            try result.append(arena, copy);
        }
    }
    return result.items;
}

fn count(arena: std.mem.Allocator, ids: *std.AutoHashMapUnmanaged(Id, Seen), id: Id, path: []const u8) !void {
    const slot = try ids.getOrPut(arena, id);
    if (!slot.found_existing) slot.value_ptr.* = .{ .path = path, .count = 0 };
    slot.value_ptr.path = path;
    slot.value_ptr.count += 1;
}

/// The path an identity moved to, when it was the only one of its kind
/// before and after.
fn pair(before: *const std.AutoHashMapUnmanaged(Id, Seen), after: *const std.AutoHashMapUnmanaged(Id, Seen), id: Id) ?[]const u8 {
    const was = before.get(id) orelse return null;
    if (was.count != 1) return null;
    const now = after.get(id) orelse return null;
    if (now.count != 1) return null;
    return now.path;
}

test "renames pair by identity and moved descendants are said by their directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = Id{ .device = 1, .inode = 10, .kind = .file };
    const dir = Id{ .device = 1, .inode = 11, .kind = .directory };
    const inner = Id{ .device = 1, .inode = 12, .kind = .file };
    var before: std.StringHashMapUnmanaged(?Entry) = .empty;
    var entries: std.StringHashMapUnmanaged(Entry) = .empty;
    try before.put(a, "a.txt", .{ .id = file, .size = 1, .mtime = 1 });
    try before.put(a, "b.txt", null);
    try before.put(a, "src", .{ .id = dir, .size = 0, .mtime = 1 });
    try before.put(a, "src/x", .{ .id = inner, .size = 1, .mtime = 1 });
    try before.put(a, "lib", null);
    try before.put(a, "lib/x", null);
    try before.put(a, "new", null);
    try entries.put(a, "b.txt", .{ .id = file, .size = 2, .mtime = 2 });
    try entries.put(a, "lib", .{ .id = dir, .size = 0, .mtime = 1 });
    try entries.put(a, "lib/x", .{ .id = inner, .size = 1, .mtime = 1 });
    try entries.put(a, "new", .{ .id = .{ .device = 1, .inode = 13, .kind = .file }, .size = 0, .mtime = 3 });
    const events = try diff(a, &before, &entries);
    try std.testing.expectEqual(4, events.len);
    try std.testing.expectEqual(Service.Op.rename, events[0].op);
    try std.testing.expectEqualStrings("a.txt", events[0].oldPath.?);
    try std.testing.expectEqualStrings("b.txt", events[0].path);
    try std.testing.expectEqual(Service.Op.write, events[1].op);
    try std.testing.expectEqualStrings("b.txt", events[1].path);
    try std.testing.expectEqual(Service.Op.rename, events[2].op);
    try std.testing.expectEqualStrings("src", events[2].oldPath.?);
    try std.testing.expectEqualStrings("lib", events[2].path);
    try std.testing.expect(events[2].isDir);
    try std.testing.expectEqual(Service.Op.create, events[3].op);
    try std.testing.expectEqualStrings("new", events[3].path);
}

test "a replaced entry is a removal and a creation; a hard link never pairs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = Id{ .device = 1, .inode = 1, .kind = .file };
    const two = Id{ .device = 1, .inode = 2, .kind = .file };
    var before: std.StringHashMapUnmanaged(?Entry) = .empty;
    var entries: std.StringHashMapUnmanaged(Entry) = .empty;
    try before.put(a, "x", .{ .id = one, .size = 1, .mtime = 1 });
    try before.put(a, "y", .{ .id = one, .size = 1, .mtime = 1 });
    try before.put(a, "z", null);
    try entries.put(a, "x", .{ .id = two, .size = 1, .mtime = 1 });
    try entries.put(a, "z", .{ .id = one, .size = 1, .mtime = 1 });
    const events = try diff(a, &before, &entries);
    try std.testing.expectEqual(4, events.len);
    try std.testing.expectEqual(Service.Op.remove, events[0].op);
    try std.testing.expectEqualStrings("x", events[0].path);
    try std.testing.expectEqual(Service.Op.create, events[1].op);
    try std.testing.expectEqualStrings("x", events[1].path);
    try std.testing.expectEqual(Service.Op.remove, events[2].op);
    try std.testing.expectEqualStrings("y", events[2].path);
    try std.testing.expectEqual(Service.Op.create, events[3].op);
    try std.testing.expectEqualStrings("z", events[3].path);
}
