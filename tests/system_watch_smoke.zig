const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
/// Zig 0.17's macOS arm64 unwinder panics on the compact-unwind encoding of
/// the system's thread-start frames, so allocation traces on the probe
/// thread are turned off there.
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };
const system = @import("ziggurat_system");
const watch = system.watch;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
const fast: watch.Options = .{ .debounce_ms = 20, .max_latency_ms = 200, .max_roots = 4, .max_directories = 256, .max_pending = 64, .pending_path_bytes = 16 * 1024, .directory_path_bytes = 32 * 1024, .native_buffer_bytes = 16 * 1024 };

const Probe = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    base: []const u8,
    dir: std.Io.Dir,
    err: ?anyerror = null,
    burst_batches: usize = 0,
    stream_ms: u64 = 0,
    carried: usize = 0,
    events: [16]watch.Event = undefined,
    storage: [16 * 1024]u8 = undefined,
    fn run(self: *Probe) void {
        self.checked() catch |err| {
            self.err = err;
        };
    }
    fn path(self: *Probe, parts: []const []const u8) ![]u8 {
        var all: [8][]const u8 = undefined;
        all[0] = self.base;
        @memcpy(all[1..][0..parts.len], parts);
        return std.fs.path.join(self.allocator, all[0 .. parts.len + 1]);
    }
    fn write(self: *Probe, sub_path: []const u8, data: []const u8) !void {
        try self.dir.writeFile(zio.io(), .{ .sub_path = sub_path, .data = data });
    }
    fn checked(self: *Probe) !void {
        const allocator = self.allocator;
        try self.dir.createDirPath(zio.io(), "tree/a/b");
        try self.dir.createDirPath(zio.io(), "tree/burst");
        try self.write("tree/a/b/x.txt", "x");
        const tree = try self.path(&.{"tree"});
        defer allocator.free(tree);
        var watcher = try watch.Watcher.init(allocator, self.main_thread, fast);
        defer watcher.deinit();
        const root = try watcher.addRoot(tree);

        if (builtin.os.tag == .macos) {
            // fseventsd numbers events as it receives them, so the writes
            // above can still arrive as hints after addRoot returns.
            while (true) {
                const early = try watcher.wait(&self.events, &self.storage, 120);
                for (early.events) |event| std.debug.print("pre-root hint: {any}\n", .{event});
                if (early.wake == .timeout and !early.more) break;
            }
        } else {
            const quiet = try watcher.wait(&self.events, &self.storage, 60);
            try std.testing.expectEqual(watch.Wake.timeout, quiet.wake);
            try std.testing.expectEqual(@as(usize, 0), quiet.events.len);
        }
        // A zero timeout still reads native events; the batch is due after debounce.
        try self.write("tree/zero.txt", "0");
        zio.sleep(30 * std.time.ns_per_ms);
        try std.testing.expectEqual(watch.Wake.timeout, (try watcher.wait(&self.events, &self.storage, 0)).wake);
        zio.sleep(60 * std.time.ns_per_ms);
        const zero = try watcher.wait(&self.events, &self.storage, 0);
        try std.testing.expectEqual(watch.Wake.batch, zero.wake);
        try std.testing.expectEqual(@as(usize, 1), zero.events.len);
        try std.testing.expectEqualStrings(tree, zero.events[0].changed.path);

        try self.write("tree/f.txt", "1");
        try self.expectChanges(&watcher, root, tree, &.{&.{}}, null);
        try self.write("tree/a/b/x.txt", "modified");
        try self.expectChanges(&watcher, root, tree, &.{&.{ "a", "b" }}, null);

        try self.dir.createDirPath(zio.io(), "tree/new/deep");
        try self.write("tree/new/deep/file.txt", "deep");
        try self.expectChanges(&watcher, root, tree, &.{ &.{}, &.{"new"}, &.{ "new", "deep" } }, null);
        try self.drain(&watcher);
        try self.write("tree/new/deep/later.txt", "later");
        try self.expectChanges(&watcher, root, tree, &.{&.{ "new", "deep" }}, null);

        try self.dir.rename("tree/a", self.dir, "tree/renamed", zio.io());
        try self.expectChanges(&watcher, root, tree, &.{&.{}}, null);
        try self.drain(&watcher);
        const old = try self.path(&.{ "tree", "a" });
        defer allocator.free(old);
        try self.write("tree/renamed/b/y.txt", "y");
        try self.expectChanges(&watcher, root, tree, &.{&.{ "renamed", "b" }}, old);
        try self.dir.deleteFile(zio.io(), "tree/renamed/b/y.txt");
        try self.expectChanges(&watcher, root, tree, &.{&.{ "renamed", "b" }}, old);
        try self.dir.deleteTree(zio.io(), "tree/renamed");
        try self.expectChanges(&watcher, root, tree, &.{&.{}}, old);
        try self.drain(&watcher);

        // Twenty writes inside one debounce window coalesce per directory.
        var burst_count: usize = 0;
        for (0..20) |index| {
            var name: [32]u8 = undefined;
            try self.write(try std.fmt.bufPrint(&name, "tree/burst/{d}.txt", .{index}), "burst");
        }
        const burst = try self.path(&.{ "tree", "burst" });
        defer allocator.free(burst);
        const burst_start = try zio.Instant.now();
        var burst_seen: ?zio.Instant = null;
        while (true) {
            const now = try zio.Instant.now();
            if (burst_seen) |seen| if (now.since(seen) > 300 * std.time.ns_per_ms) break;
            if (now.since(burst_start) > 5 * std.time.ns_per_s) return error.MissingEvent;
            const batch = try watcher.wait(&self.events, &self.storage, 100);
            try expectUnique(batch.events);
            for (batch.events) |event| {
                if (event == .changed and std.mem.eql(u8, event.changed.path, burst)) {
                    burst_count += 1;
                    if (burst_seen == null) burst_seen = try zio.Instant.now();
                }
            }
        }
        try std.testing.expect(burst_count >= 1 and burst_count <= 2);
        self.burst_batches = burst_count;

        // Continuous writes never go quiet; max_latency still bounds the batch.
        try self.dir.createDirPath(zio.io(), "tree/stream");
        try self.drain(&watcher);
        var writer: Writer = .{ .dir = self.dir };
        const writing = try std.Thread.spawn(.{}, Writer.run, .{&writer});
        const stream_start = try zio.Instant.now();
        var first_batch: ?u64 = null;
        while (first_batch == null) {
            const batch = try watcher.wait(&self.events, &self.storage, 2000);
            if (batch.events.len != 0) first_batch = (try zio.Instant.now()).since(stream_start);
            if (batch.wake == .timeout) break;
        }
        writing.join();
        try std.testing.expect(first_batch != null);
        try std.testing.expect(first_batch.? < 600 * std.time.ns_per_ms);
        self.stream_ms = first_batch.? / std.time.ns_per_ms;
        try self.drain(&watcher);

        // Caller capacity: one event per wait, remaining due events carried over.
        for ([_][]const u8{ "c1", "c2", "c3", "c4", "c5" }) |name| {
            const directory = try std.fmt.allocPrint(allocator, "tree/{s}", .{name});
            defer allocator.free(directory);
            try self.dir.createDirPath(zio.io(), directory);
        }
        try self.drain(&watcher);
        for ([_][]const u8{ "c1", "c2", "c3", "c4", "c5" }) |name| {
            const file = try std.fmt.allocPrint(allocator, "tree/{s}/file", .{name});
            defer allocator.free(file);
            try self.write(file, "carry");
        }
        var tiny: [1]u8 = undefined;
        var one: [1]watch.Event = undefined;
        var carried: usize = 0;
        var continued = false;
        var first = true;
        while (true) {
            if (first) {
                // Nothing fits: error without consuming anything.
                zio.sleep(150 * std.time.ns_per_ms);
                try std.testing.expectError(error.ResultCapacityExceeded, watcher.wait(&one, &tiny, 1000));
                first = false;
            }
            const batch = try watcher.wait(&one, &self.storage, 1000);
            if (batch.events.len == 0) break;
            try std.testing.expectEqual(@as(usize, 1), batch.events.len);
            carried += 1;
            if (batch.more) continued = true;
            if (!batch.more) break;
        }
        try std.testing.expect(carried >= 5 and continued);
        self.carried = carried;
        try std.testing.expectError(error.ResultCapacityExceeded, watcher.wait(&.{}, &self.storage, 0));
        try self.drain(&watcher);

        // Interrupt from another thread, and a pre-posted interrupt.
        var waker: Waker = .{ .watcher = &watcher };
        const waking = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        const interrupted = try watcher.wait(&self.events, &self.storage, null);
        waking.join();
        try std.testing.expectEqual(watch.Wake.interrupted, interrupted.wake);
        try std.testing.expectEqual(@as(?anyerror, error.WrongThread), waker.wait_error);
        watcher.interrupt();
        watcher.interrupt();
        try std.testing.expectEqual(watch.Wake.interrupted, (try watcher.wait(&self.events, &self.storage, null)).wake);
        try std.testing.expectEqual(watch.Wake.timeout, (try watcher.wait(&self.events, &self.storage, 30)).wake);

        // Root removal releases the root; its id becomes stale.
        try self.dir.createDirPath(zio.io(), "doomed/inner");
        const doomed_path = try self.path(&.{"doomed"});
        defer allocator.free(doomed_path);
        const doomed = try watcher.addRoot(doomed_path);
        if (builtin.os.tag == .linux) {
            const inner = try self.path(&.{ "doomed", "inner" });
            defer allocator.free(inner);
            try std.testing.expectError(error.OverlappingRoot, watcher.addRoot(inner));
        }
        try self.dir.deleteTree(zio.io(), "doomed");
        try self.expectRemoved(&watcher, doomed);
        try std.testing.expectError(error.UnknownRoot, watcher.removeRoot(doomed));
        try std.testing.expectError(error.UnknownRoot, watcher.isIncomplete(doomed));
        try std.testing.expect(!try watcher.isIncomplete(root));
        try watcher.removeRoot(root);
        try std.testing.expectError(error.UnknownRoot, watcher.removeRoot(root));
        try std.testing.expectError(error.FileNotFound, watcher.addRoot(doomed_path));
        try std.testing.expectError(error.AbsolutePathRequired, watcher.addRoot("relative"));

        try self.pendingOverflow();
        if (builtin.os.tag == .linux) try self.directoryBudget();
        try self.nonRecursive();

        watcher.deinit();
        watcher.deinit();
        try std.testing.expectError(error.Closed, watcher.wait(&self.events, &self.storage, 0));
        try self.handlesStable();
    }
    fn pendingOverflow(self: *Probe) !void {
        try self.dir.createDirPath(zio.io(), "pending/p1");
        try self.dir.createDirPath(zio.io(), "pending/p2");
        try self.dir.createDirPath(zio.io(), "pending/p3");
        try self.dir.createDirPath(zio.io(), "pending/p4");
        const pending = try self.path(&.{"pending"});
        defer self.allocator.free(pending);
        var options = fast;
        options.max_pending = 2;
        options.debounce_ms = 100;
        options.max_latency_ms = 400;
        var watcher = try watch.Watcher.init(self.allocator, self.main_thread, options);
        defer watcher.deinit();
        const root = try watcher.addRoot(pending);
        for ([_][]const u8{ "p1", "p2", "p3", "p4" }) |name| {
            const file = try std.fmt.allocPrint(self.allocator, "pending/{s}/file", .{name});
            defer self.allocator.free(file);
            try self.write(file, "full");
        }
        try self.expectOverflow(&watcher, root, .pending_capacity);
        try std.testing.expect(!try watcher.isIncomplete(root));
    }
    fn directoryBudget(self: *Probe) !void {
        try self.dir.createDirPath(zio.io(), "budget/s1");
        try self.dir.createDirPath(zio.io(), "budget/s2");
        const budget = try self.path(&.{"budget"});
        defer self.allocator.free(budget);
        var options = fast;
        options.max_directories = 2;
        options.max_roots = 2;
        var small = try watch.Watcher.init(self.allocator, self.main_thread, options);
        defer small.deinit();
        try std.testing.expectError(error.DirectoryBudgetExceeded, small.addRoot(budget));
        options.max_directories = 3;
        var watcher = try watch.Watcher.init(self.allocator, self.main_thread, options);
        defer watcher.deinit();
        const root = try watcher.addRoot(budget);
        try self.dir.createDirPath(zio.io(), "budget/s3");
        try self.expectOverflow(&watcher, root, .incomplete_tree);
        try std.testing.expect(try watcher.isIncomplete(root));
        // Released watches are reusable after the host removes and re-adds.
        try watcher.removeRoot(root);
        try self.dir.deleteTree(zio.io(), "budget/s3");
        const again = try watcher.addRoot(budget);
        try std.testing.expect(!try watcher.isIncomplete(again));
    }
    fn nonRecursive(self: *Probe) !void {
        try self.dir.createDirPath(zio.io(), "flat/child");
        const flat = try self.path(&.{"flat"});
        defer self.allocator.free(flat);
        var options = fast;
        options.recursive = false;
        var watcher = try watch.Watcher.init(self.allocator, self.main_thread, options);
        defer watcher.deinit();
        const root = try watcher.addRoot(flat);
        try self.write("flat/child/ignored.txt", "nested");
        const batch = try watcher.wait(&self.events, &self.storage, 300);
        for (batch.events) |event| if (event == .changed) try std.testing.expectEqualStrings(flat, event.changed.path);
        try self.write("flat/top.txt", "top");
        try self.expectChanges(&watcher, root, flat, &.{&.{}}, null);
    }
    fn handlesStable(self: *Probe) !void {
        try self.dir.createDirPath(zio.io(), "rounds/a/b");
        const rounds = try self.path(&.{"rounds"});
        defer self.allocator.free(rounds);
        const baseline = try handles();
        for (0..12) |round| {
            var watcher = try watch.Watcher.init(self.allocator, self.main_thread, fast);
            const root = try watcher.addRoot(rounds);
            if (round % 2 == 0) {
                try self.write("rounds/a/b/file", "round");
                try self.expectChanges(&watcher, root, rounds, &.{&.{ "a", "b" }}, null);
            }
            watcher.interrupt();
            watcher.deinit();
            watcher.deinit();
        }
        const after = try handles();
        if (after != baseline) std.debug.print("watch handles: before={d}, after={d}\n", .{ baseline, after });
        try std.testing.expectEqual(baseline, after);
    }
    fn drain(self: *Probe, watcher: *watch.Watcher) !void {
        while (true) {
            const batch = try watcher.wait(&self.events, &self.storage, 120);
            if (batch.wake == .timeout and !batch.more) return;
        }
    }
    fn expectChanges(self: *Probe, watcher: *watch.Watcher, root: watch.Root, root_path: []const u8, expected: []const []const []const u8, forbidden: ?[]const u8) !void {
        var wanted: [8][]u8 = undefined;
        for (expected, 0..) |parts, index| {
            var all: [8][]const u8 = undefined;
            all[0] = root_path;
            @memcpy(all[1..][0..parts.len], parts);
            wanted[index] = try std.fs.path.join(self.allocator, all[0 .. parts.len + 1]);
        }
        defer for (wanted[0..expected.len]) |text| self.allocator.free(text);
        var seen: [8]bool = @splat(false);
        const start = try zio.Instant.now();
        while (std.mem.indexOfScalar(bool, seen[0..expected.len], false) != null) {
            if ((try zio.Instant.now()).since(start) > 5 * std.time.ns_per_s) {
                for (wanted[0..expected.len], seen[0..expected.len]) |text, hit| if (!hit) std.debug.print("missing changed: {s}\n", .{text});
                return error.MissingEvent;
            }
            const batch = try watcher.wait(&self.events, &self.storage, 250);
            try expectUnique(batch.events);
            for (batch.events) |event| switch (event) {
                .changed => |change| {
                    try std.testing.expect(change.root.eql(root));
                    if (forbidden) |prefix| if (std.mem.startsWith(u8, change.path, prefix)) {
                        std.debug.print("stale path reported: {s}\n", .{change.path});
                        return error.StalePath;
                    };
                    for (wanted[0..expected.len], 0..) |text, index| {
                        if (std.mem.eql(u8, text, change.path)) seen[index] = true;
                    }
                },
                else => {
                    std.debug.print("unexpected event: {any}\n", .{event});
                    return error.UnexpectedEvent;
                },
            };
        }
    }
    fn expectOverflow(self: *Probe, watcher: *watch.Watcher, root: watch.Root, reason: watch.OverflowReason) !void {
        const start = try zio.Instant.now();
        while ((try zio.Instant.now()).since(start) < 5 * std.time.ns_per_s) {
            const batch = try watcher.wait(&self.events, &self.storage, 250);
            for (batch.events) |event| if (event == .overflow and event.overflow.root.eql(root)) {
                try std.testing.expectEqual(reason, event.overflow.reason);
                return;
            };
        }
        return error.MissingOverflow;
    }
    fn expectRemoved(self: *Probe, watcher: *watch.Watcher, root: watch.Root) !void {
        const start = try zio.Instant.now();
        while ((try zio.Instant.now()).since(start) < 5 * std.time.ns_per_s) {
            const batch = try watcher.wait(&self.events, &self.storage, 250);
            for (batch.events) |event| if (event == .root_removed and event.root_removed.root.eql(root)) return;
        }
        return error.MissingRootRemoved;
    }
};
fn expectUnique(events: []const watch.Event) !void {
    for (events, 0..) |event, index| {
        if (event != .changed) continue;
        for (events[index + 1 ..]) |other| {
            if (other == .changed and other.changed.root.eql(event.changed.root) and std.mem.eql(u8, other.changed.path, event.changed.path)) return error.DuplicateInBatch;
        }
    }
}
const Writer = struct {
    dir: std.Io.Dir,
    fn run(self: *Writer) void {
        for (0..120) |index| {
            var name: [48]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&name, "tree/stream/{d}.txt", .{index % 8}) catch return;
            self.dir.writeFile(zio.io(), .{ .sub_path = sub_path, .data = "stream" }) catch return;
            zio.sleep(5 * std.time.ns_per_ms);
        }
    }
};
const Waker = struct {
    watcher: *watch.Watcher,
    wait_error: ?anyerror = null,
    fn run(self: *Waker) void {
        var events: [1]watch.Event = undefined;
        var storage: [16]u8 = undefined;
        _ = self.watcher.wait(&events, &storage, 0) catch |err| {
            self.wait_error = err;
        };
        zio.sleep(80 * std.time.ns_per_ms);
        self.watcher.interrupt();
    }
};
fn handles() !usize {
    if (builtin.os.tag == .windows) {
        var count: c.DWORD = 0;
        if (c.GetProcessHandleCount(c.GetCurrentProcess(), &count) == 0) return error.HandleCountUnavailable;
        return count;
    }
    const listing = if (builtin.os.tag == .macos) "/dev/fd" else "/proc/self/fd";
    var directory = try std.Io.Dir.openDirAbsolute(zio.io(), listing, .{ .iterate = true });
    defer directory.close(zio.io());
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(zio.io())) |_| count += 1;
    return count;
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try std.testing.expect(system.capabilities.file_watch and watch.capabilities.coarse and !watch.capabilities.detailed);
    try std.testing.expectError(error.UiThreadForbidden, watch.Watcher.init(allocator, std.Thread.getCurrentId(), .{}));
    var temporary = zio.tmpDir(.{});
    defer temporary.cleanup();
    const base = try zio.realPathAlloc(temporary.dir, ".", allocator);
    defer allocator.free(base);
    var probe: Probe = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .base = base, .dir = temporary.dir };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    if (probe.err) |err| return err;
    std.debug.print("file-watch smoke passed: coarse create/modify/rename/delete/nested, debounce and latency bound, carry-over, interrupt/timeout, overflow, root removal, 12 rounds handles stable (burst batches={d}, first streaming batch={d} ms, carried waits={d})\n", .{ probe.burst_batches, probe.stream_ms, probe.carried });
}
