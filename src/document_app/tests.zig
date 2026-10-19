const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("root.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

const io: d.Files = .{ .ui_thread = null };

const Host = struct {
    blocked: usize = 0,
    last_reason: ?z.CloseReason = null,
    quit_blocked: usize = 0,
    changed: usize = 0,
    released: [8]d.Released = undefined,
    released_len: usize = 0,
    fn closeBlocked(context: *anyopaque, _: *d.Registry, _: d.DocumentId, reason: z.CloseReason) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.blocked += 1;
        self.last_reason = reason;
    }
    fn quitBlocked(context: *anyopaque, _: *d.Registry) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.quit_blocked += 1;
    }
    fn onChanged(context: *anyopaque, _: *d.Registry, _: d.DocumentId) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.changed += 1;
    }
    fn onReleased(context: *anyopaque, _: *d.Registry, value: d.Released) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.released[self.released_len] = value;
        self.released_len += 1;
    }
    fn handlers(self: *Host) d.Handlers {
        return .{ .context = self, .close_blocked = closeBlocked, .quit_blocked = quitBlocked, .changed = onChanged, .released = onReleased };
    }
};

fn absolutePath(dir: std.fs.Dir, name: []const u8, buffer: []u8) ![]const u8 {
    var parent: [std.fs.max_path_bytes]u8 = undefined;
    const root = try dir.realpath(".", &parent);
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ root, std.fs.path.sep_str, name });
}
fn identityOf(path: []const u8) d.Identity {
    return .{ .path = d.Path.init(path) catch unreachable };
}
fn open(registry: *d.Registry, app: *z.App, path: []const u8) !struct { d.DocumentId, z.Window } {
    const identity = identityOf(path);
    const document = switch (try registry.claim(&identity)) {
        .reserved => |value| value,
        .existing => return error.Unexpected,
    };
    const window = try app.createWindow(.{ .on_close = registry.closeHandler(), .on_closed = registry.closedHandler() });
    try registry.attach(document, window, null);
    return .{ document, window };
}

test "identity resolution canonicalizes aliases and claims return the existing document" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "alpha" });
    try tmp.dir.symLink("notes.txt", "alias.txt", .{});
    try std.posix.linkat(tmp.dir.fd, "notes.txt", tmp.dir.fd, "hard.txt", 0);
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    var c: [std.fs.max_path_bytes]u8 = undefined;
    const real = try io.resolve(try absolutePath(tmp.dir, "notes.txt", &a));
    const alias = try io.resolve(try absolutePath(tmp.dir, "alias.txt", &b));
    const hard = try io.resolve(try absolutePath(tmp.dir, "hard.txt", &c));
    try expect(real.path.eql(&alias.path) and real.key.known());
    try expect(!real.path.eql(&hard.path) and real.eql(&hard));
    try std.testing.expectError(error.InvalidPath, io.resolve("relative.txt"));
    const ui: d.Files = .{ .ui_thread = std.Thread.getCurrentId() };
    try std.testing.expectError(error.UiThreadIo, ui.resolve(real.path.slice()));

    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [2]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const first = (try registry.claim(&real)).reserved;
    // A duplicate open while the first is still loading joins it.
    try equal(first, (try registry.claim(&hard)).existing);
    try expect(!try registry.reveal(first));
    const window = try app.createWindow(.{ .on_close = registry.closeHandler(), .on_closed = registry.closedHandler() });
    try registry.attach(first, window, null);
    try std.testing.expectError(error.AlreadyAttached, registry.attach(first, window, null));
    try equal(first, (try registry.claim(&alias)).existing);
    try expect(try registry.reveal(first));
    try expect((try window.state()).focused);
    const untitled = try registry.claimUntitled();
    try std.testing.expectError(error.CapacityExceeded, registry.claimUntitled());
    var name: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Untitled 1", try registry.displayName(untitled, &name));
    try std.testing.expectEqualStrings("notes.txt", try registry.displayName(first, &name));
    try registry.cancel(untitled);
    try std.testing.expectError(error.StaleDocument, registry.info(untitled));
    try equal(@as(usize, 1), registry.count());
}

test "dirty documents veto close until discarded and an edit revokes the discard" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [4]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const document, const window = try open(&registry, app, "/docs/a.txt");
    try equal(z.CloseResult.closed, try (try app.createWindow(.{ .on_close = registry.closeHandler() })).requestClose());
    try registry.edited(document, 10);
    try equal(@as(usize, 1), host.changed);
    try registry.edited(document, 11);
    try equal(@as(usize, 1), host.changed);
    try equal(z.CloseResult.cancelled, try window.requestCloseFrom(.user));
    try equal(@as(usize, 1), host.blocked);
    try equal(z.CloseReason.user, (try registry.info(document)).pending_close.?);
    try registry.discard(document);
    try registry.edited(document, 12);
    try equal(z.CloseResult.cancelled, try window.requestCloseFrom(.user));
    try equal(@as(usize, 2), host.blocked);
    try registry.discard(document);
    try equal(z.CloseResult.closed, try window.requestCloseFrom(.user));
    try equal(@as(usize, 1), host.released_len);
    try expect(!host.released[0].unsaved);
    try std.testing.expectError(error.StaleDocument, registry.info(document));
    try equal(@as(usize, 0), registry.count());
}

test "quit preflights every dirty document before any window closes" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [4]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const a, const window_a = try open(&registry, app, "/docs/a.txt");
    const b, const window_b = try open(&registry, app, "/docs/b.txt");
    _ = try open(&registry, app, "/docs/clean.txt");
    try registry.edited(a, 1);
    try registry.edited(b, 1);
    try equal(z.App.QuitResult.cancelled, registry.requestQuit());
    try equal(@as(usize, 1), host.quit_blocked);
    var ids: [4]d.DocumentId = undefined;
    try equal(@as(usize, 2), registry.blocking(&ids).len);
    try expect(!window_a.isClosed() and !window_b.isClosed());
    // The App's own quit preflight reaches the registry through on_close too.
    try equal(z.App.QuitResult.cancelled, app.requestQuit());
    try equal(@as(usize, 2), host.quit_blocked);
    try equal(@as(usize, 0), host.blocked);

    // Save one document: its outcome asks for the quit to be retried.
    const ticket = try registry.beginSave(a, .normal);
    try std.testing.expectError(error.SaveInProgress, registry.beginSave(a, .normal));
    const outcome = try registry.finishSave(&ticket, .{ .size = 1, .mtime_ns = 1, .key = .{ .device = 1, .inode = 9 } });
    try expect(outcome.clean);
    try equal(z.CloseReason.quit, outcome.retry_close.?);
    try equal(z.App.QuitResult.cancelled, registry.requestQuit());
    registry.discardAll();
    try equal(@as(usize, 0), registry.blocking(&ids).len);
    try equal(z.App.QuitResult.accepted, registry.requestQuit());
    try equal(z.App.Phase.stopping, app.phase);
}

test "abandoning a prompt clears the pending close and quit" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [2]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const a, _ = try open(&registry, app, "/docs/a.txt");
    try registry.edited(a, 1);
    _ = registry.requestQuit();
    try expect(registry.quit_pending);
    try registry.abandonClose(a);
    try expect(!registry.quit_pending);
    try equal(@as(?z.CloseReason, null), (try registry.info(a)).pending_close);
    const ticket = try registry.beginSave(a, .normal);
    try equal(@as(?z.CloseReason, null), (try registry.finishSave(&ticket, .{ .size = 0, .mtime_ns = 0, .key = .{} })).retry_close);
}

test "forced destruction of a dirty document reports unsaved work for recovery" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [2]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const a, const window = try open(&registry, app, "/docs/a.txt");
    try registry.edited(a, 1);
    const snapshot = try registry.beginSnapshot(a);
    try equal(d.SnapshotOutcome.kept, registry.finishSnapshot(&snapshot));
    _ = try window.destroy();
    try equal(@as(usize, 1), host.released_len);
    const released = host.released[0];
    try expect(released.unsaved and released.snapshot);
    try std.testing.expectEqualStrings(d.RecoveryName.forKind(&.{ .file = identityOf("/docs/a.txt") }).slice(), released.recovery.slice());
    // A save for the released document cannot touch the reused slot.
    const b, _ = try open(&registry, app, "/docs/b.txt");
    try equal(a.index, b.index);
    try std.testing.expectError(error.StaleDocument, registry.beginSave(a, .normal));
}

test "autosave and snapshot deadlines debounce edits, cap delay and pause on conflict" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [3]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{ .autosave_delay_ns = 10, .autosave_max_delay_ns = 25, .snapshot_delay_ns = 4, .snapshot_max_delay_ns = 100 }, host.handlers());
    const a, _ = try open(&registry, app, "/docs/a.txt");
    const untitled = try registry.claimUntitled();
    try registry.attach(untitled, try app.createWindow(.{}), null);
    try equal(@as(?i128, null), registry.nextDeadline());
    var due: [4]d.DocumentId = undefined;
    try registry.edited(a, 100);
    try registry.edited(untitled, 100);
    try equal(@as(?i128, 104), registry.nextDeadline());
    try equal(@as(usize, 2), registry.dueSnapshots(104, &due).len);
    try registry.edited(a, 108);
    try equal(@as(usize, 0), registry.dueAutosaves(117, &due).len);
    try registry.edited(a, 116);
    // Max delay from the first unsaved edit wins over continued typing.
    try equal(@as(usize, 1), registry.dueAutosaves(125, &due).len);
    try equal(a, due[0]);
    try std.testing.expectError(error.Untitled, registry.beginSave(untitled, .normal));
    const flushed = registry.dueAutosaves(std.math.maxInt(i128), &due);
    try equal(@as(usize, 1), flushed.len);
    const ticket = try registry.beginSave(a, .normal);
    try equal(@as(usize, 0), registry.dueAutosaves(std.math.maxInt(i128), &due).len);
    try registry.conflictSave(&ticket);
    try expect((try registry.info(a)).conflict);
    try equal(@as(usize, 0), registry.dueAutosaves(std.math.maxInt(i128), &due).len);
    try std.testing.expectError(error.Conflict, registry.beginSave(a, .normal));
    const overwrite = try registry.beginSave(a, .overwrite);
    try equal(@as(?d.Stamp, null), overwrite.expected);
    try registry.edited(a, 130);
    const outcome = try registry.finishSave(&overwrite, .{ .size = 0, .mtime_ns = 0, .key = .{} });
    try expect(!outcome.clean and !(try registry.info(a)).conflict);
    try equal(@as(usize, 1), registry.dueAutosaves(std.math.maxInt(i128), &due).len);
}

test "snapshots become obsolete after save, rename or a newer save" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var host: Host = .{};
    var slots: [3]d.Slot = undefined;
    var registry = d.Registry.init(app, &slots, .{}, host.handlers());
    const untitled = try registry.claimUntitled();
    try registry.attach(untitled, try app.createWindow(.{}), null);
    try std.testing.expectError(error.Clean, registry.beginSnapshot(untitled));
    try registry.edited(untitled, 1);
    const first = try registry.beginSnapshot(untitled);
    try std.testing.expectError(error.SnapshotInProgress, registry.beginSnapshot(untitled));
    try equal(d.SnapshotOutcome.kept, registry.finishSnapshot(&first));
    var due: [2]d.DocumentId = undefined;
    try equal(@as(usize, 0), registry.dueSnapshots(std.math.maxInt(i128), &due).len);
    try registry.edited(untitled, 2);
    const second = try registry.beginSnapshot(untitled);
    const target = identityOf("/docs/new.txt");
    _ = try open(&registry, app, "/docs/taken.txt");
    try std.testing.expectError(error.AlreadyOpen, registry.beginSaveAs(untitled, &identityOf("/docs/taken.txt")));
    const save = try registry.beginSaveAs(untitled, &target);
    const outcome = try registry.finishSave(&save, .{ .size = 3, .mtime_ns = 5, .key = .{ .device = 2, .inode = 3 } });
    try expect(outcome.clean);
    try std.testing.expectEqualStrings("u1", outcome.obsolete_snapshot.?.slice());
    try equal(d.SnapshotOutcome.obsolete, registry.finishSnapshot(&second));
    const info = try registry.info(untitled);
    try expect(info.kind.* == .file and info.kind.file.key.inode == 3);
    try equal(untitled, registry.find(&target).?);
}

test "atomic save replaces content, keeps mode and refuses external modifications" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.txt", .data = "one" });
    const file = try tmp.dir.openFile("doc.txt", .{});
    try file.chmod(0o640);
    file.close();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try absolutePath(tmp.dir, "doc.txt", &path_buffer);
    var content: [64]u8 = undefined;
    const loaded = try io.read(path, &content);
    try std.testing.expectEqualStrings("one", loaded.bytes);
    try std.testing.expectError(error.CapacityExceeded, io.read(path, content[0..2]));
    try equal(d.Probe.unchanged, try io.probe(path, loaded.stamp));
    var write_buffer: [16]u8 = undefined;
    const saved = (try io.save(path, "second", &write_buffer, .{ .expected = loaded.stamp })).saved;
    try equal(@as(u64, 6), saved.size);
    try equal(@as(std.fs.File.Mode, 0o640), saved.mode & 0o777);
    try expect(saved.key.inode != loaded.stamp.key.inode);
    try std.testing.expectEqualStrings("second", (try io.read(path, &content)).bytes);
    // Another program rewrites the file: the stale stamp is now a conflict.
    try tmp.dir.writeFile(.{ .sub_path = "doc.txt", .data = "external!" });
    const result = try io.save(path, "third", &write_buffer, .{ .expected = saved });
    try expect(result == .conflict and result.conflict == .modified);
    try std.testing.expectEqualStrings("external!", (try io.read(path, &content)).bytes);
    try expect((try io.probe(path, saved)) == .modified);
    try tmp.dir.deleteFile("doc.txt");
    try equal(d.Probe.missing, try io.probe(path, saved));
    try expect((try io.save(path, "fourth", &write_buffer, .{ .expected = saved })).conflict == .missing);
    try expect((try io.save(path, "fourth", &write_buffer, .{})) == .saved);
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = try io.resolveTarget(try absolutePath(tmp.dir, "fresh.txt", &target_buffer));
    try expect(!target.key.known() and std.mem.endsWith(u8, target.path.slice(), "/fresh.txt"));
    var iterator = tmp.dir.iterate();
    var names: usize = 0;
    while (try iterator.next()) |_| names += 1;
    try equal(@as(usize, 1), names);
}

test "recent documents keep newest first, deduplicate, evict and round trip" {
    var storage: [3]d.Path = undefined;
    var recent = d.Recent.init(&storage);
    try recent.add("/a");
    try recent.add("/b");
    try recent.add("/c");
    try recent.add("/a");
    try recent.add("/d");
    try equal(@as(usize, 3), recent.items().len);
    try std.testing.expectEqualStrings("/d", recent.items()[0].slice());
    try std.testing.expectEqualStrings("/a", recent.items()[1].slice());
    try std.testing.expectEqualStrings("/c", recent.items()[2].slice());
    try std.testing.expectError(error.InvalidPath, recent.add("relative"));
    try std.testing.expectError(error.InvalidPath, recent.add("/bad\nline"));
    var bytes: [128]u8 = undefined;
    const encoded = try recent.encode(&bytes);
    var other_storage: [2]d.Path = undefined;
    var other = d.Recent.init(&other_storage);
    try other.decode(encoded);
    try equal(@as(usize, 2), other.items().len);
    try std.testing.expectEqualStrings("/d", other.items()[0].slice());
    try std.testing.expectEqualStrings("/a", other.items()[1].slice());
    try std.testing.expectError(error.InvalidFormat, other.decode("ziggurat-recent 1\nrelative\n"));
    try equal(@as(usize, 2), other.items().len);
    try other.decode("ziggurat-recent 1\n");
    try equal(@as(usize, 0), other.items().len);
    try expect(recent.remove("/a") and !recent.remove("/a"));
    try equal(@as(usize, 2), recent.items().len);
}

test "recovery snapshots round trip, reject corruption and survive only unlocked sessions" {
    const snapshot: d.Snapshot = .{ .path = "/docs/a.txt", .base = .{ .size = 4, .mtime_ns = -7, .key = .{ .device = 1, .inode = 2 } }, .revision = 9, .saved_ns = 1234, .content = "unsaved text" };
    var bytes: [256]u8 = undefined;
    const encoded = try snapshot.encode(&bytes);
    try equal(snapshot.encodedLen(), encoded.len);
    const decoded = try d.Snapshot.decode(encoded);
    try std.testing.expectEqualStrings("/docs/a.txt", decoded.path.?);
    try std.testing.expectEqualStrings("unsaved text", decoded.content);
    try expect(decoded.base.?.eql(snapshot.base.?) and decoded.revision == 9 and decoded.saved_ns == 1234);
    var corrupt = bytes;
    corrupt[encoded.len - 6] ^= 1;
    try std.testing.expectError(error.Corrupt, d.Snapshot.decode(corrupt[0..encoded.len]));
    try std.testing.expectError(error.InvalidFormat, d.Snapshot.decode(encoded[0..10]));
    const untitled = try d.Snapshot.decode(try (d.Snapshot{ .revision = 1, .saved_ns = 0, .content = "" }).encode(&bytes));
    try expect(untitled.path == null and untitled.base == null);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var live = try d.Session.open(io, tmp.dir, 0xa1);
    try std.testing.expectError(error.SessionInUse, d.Session.adopt(io, tmp.dir, 0xa1));
    var crashed = try d.Session.open(io, tmp.dir, 0xb2);
    const name = try d.RecoveryName.parse("u3");
    var write_buffer: [32]u8 = undefined;
    try crashed.write(&name, snapshot, &bytes, &write_buffer);
    try crashed.dir.writeFile(.{ .sub_path = "unrelated.tmp", .data = "x" });
    crashed.close();
    var found: [4]u64 = undefined;
    const orphans = try d.recovery.orphans(io, tmp.dir, 0xa1, &found);
    try equal(@as(usize, 1), orphans.len);
    try equal(@as(u64, 0xb2), orphans[0]);
    var adopted = try d.Session.adopt(io, tmp.dir, 0xb2);
    var names: [4]d.RecoveryName = undefined;
    const listed = try adopted.list(&names);
    try equal(@as(usize, 1), listed.len);
    var read_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("unsaved text", (try adopted.read(&listed[0], &read_buffer)).content);
    try std.testing.expectError(error.CapacityExceeded, adopted.read(&listed[0], read_buffer[0..20]));
    try adopted.remove(&listed[0]);
    try adopted.remove(&listed[0]);
    try adopted.finish(tmp.dir, 0xb2);
    try equal(@as(usize, 0), (try d.recovery.orphans(io, tmp.dir, 0xa1, &found)).len);
    try live.finish(tmp.dir, 0xa1);
    try std.testing.expectError(error.InvalidName, d.RecoveryName.parse("x1"));
}
