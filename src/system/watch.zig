const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const linux = std.os.linux;
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag == .macos;
/// coarse: directory-level hints of what to recheck, never file identity.
pub const capabilities = .{
    .coarse = is_linux or is_windows or is_darwin,
    .detailed = false,
};
/// Longest root or reported path in UTF-8 bytes (Linux and macOS PATH_MAX
/// without NUL; Windows 32767 UTF-16 units at three bytes each).
pub const max_path_bytes: usize = if (is_windows) 32767 * 3 else if (is_darwin) 1023 else 4095;
pub const max_roots_limit: u16 = if (is_windows) 63 else 1024;

pub const Options = struct {
    /// Linux walks subdirectories within max_directories; Windows uses the
    /// native subtree flag with one handle per root; macOS one FSEvents
    /// stream per root, which always covers the subtree and is filtered to
    /// the root itself when false.
    recursive: bool = true,
    /// Quiet interval after the latest native event before a batch is due.
    debounce_ms: u32 = 50,
    /// Upper bound from the first undelivered event until the batch is due.
    max_latency_ms: u32 = 500,
    max_roots: u16 = 8,
    /// Linux: inotify watches, one per watched directory. Windows and macOS:
    /// one per root.
    max_directories: u32 = 4096,
    /// Distinct undelivered (root, directory) pairs; coalescing is a linear scan.
    max_pending: u32 = 512,
    pending_path_bytes: u32 = 128 * 1024,
    /// Path bytes of all watched directories; held twice for compaction.
    directory_path_bytes: u32 = 512 * 1024,
    /// Linux: one inotify read buffer. Windows: one ReadDirectoryChangesW buffer
    /// per root; network shares reject buffers above 64 KiB.
    native_buffer_bytes: u32 = 64 * 1024,
};
pub const Root = struct {
    index: u32,
    generation: u32,
    pub fn eql(a: Root, b: Root) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};
pub const OverflowReason = enum {
    /// IN_Q_OVERFLOW or a zero-byte / ERROR_NOTIFY_ENUM_DIR completion.
    native_queue,
    /// max_pending or pending_path_bytes was exhausted before delivery.
    pending_capacity,
    /// A subdirectory could not be watched (budget, system watch limit,
    /// access, path length). The root stays incomplete until removed.
    incomplete_tree,
};
pub const Event = union(enum) {
    /// Entries of `path` changed; re-list it. `path` borrows wait's storage.
    changed: struct { root: Root, path: []const u8 },
    /// Rescan the whole root. Its undelivered `changed` events were dropped.
    overflow: struct { root: Root, reason: OverflowReason },
    /// The root was deleted, moved or became unwatchable. Delivering this
    /// event releases the root; its id is stale afterwards.
    root_removed: struct { root: Root },
};
pub const Wake = enum { batch, timeout, interrupted };
pub const Batch = struct {
    events: []Event,
    wake: Wake,
    /// Undelivered work remains. When it is already due, the next wait
    /// returns immediately.
    more: bool,
};
pub const NativeFailure = struct { domain: enum { errno, win32 }, code: u32 };

const RootState = struct {
    generation: u32 = 0,
    state: enum { free, active, removed } = .free,
    directory: u32 = 0,
    overflow: ?OverflowReason = null,
    incomplete: bool = false,
    native: if (is_windows) WindowsRoot else if (is_darwin) DarwinRoot else void = if (is_windows or is_darwin) .{} else {},
};
const DarwinRoot = struct {
    stream: ?cf.Ref = null,
    /// Directory slot holding the resolved path FSEvents reports under.
    canonical: u32 = 0,
    device: i64 = 0,
    inode: u64 = 0,
};
const WindowsRoot = struct {
    handle: win.HANDLE = null,
    overlapped: win.OVERLAPPED = std.mem.zeroes(win.OVERLAPPED),
    reading: bool = false,
};

/// Coarse directory watcher on a caller-created worker thread. init allocates
/// every buffer; later calls do not allocate. All methods except interrupt run
/// on the creating thread. Do not copy after init; keep the address stable
/// while other threads may call interrupt.
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread.Id,
    options: Options,
    closed: bool = false,
    roots: []RootState,
    directories: Directories,
    pending: Pending,
    scratch: []u8,
    native_buffer: []align(8) u8,
    walk: []u32,
    descriptors: if (is_linux) DescriptorTable else void,
    inotify: if (is_linux) i32 else void,
    wake_fd: if (is_linux) i32 else void,
    wake_event: if (is_windows) win.HANDLE else void,
    run_loop: if (is_darwin) cf.Ref else void,
    run_mode: if (is_darwin) cf.Ref else void,
    wake_source: if (is_darwin) cf.Ref else void,
    /// Heap flag the wake source sets on the watcher thread, so init can
    /// return the watcher by value.
    woken: if (is_darwin) *bool else void,
    /// Inside block's run of the loop; callbacks outside it must not stop it.
    in_run: bool = false,
    /// Events FSEvents flushes while a root is being added predate it.
    priming: bool = false,
    first: ?zio.Instant = null,
    last: ?zio.Instant = null,
    due: bool = false,
    last_failure: ?NativeFailure = null,

    pub fn init(allocator: std.mem.Allocator, main_thread: std.Thread.Id, options: Options) !Watcher {
        const thread = std.Thread.getCurrentId();
        if (thread == main_thread) return error.UiThreadForbidden;
        if (!capabilities.coarse) return error.UnsupportedCapability;
        try validate(options);
        const roots = try allocator.alloc(RootState, options.max_roots);
        errdefer allocator.free(roots);
        @memset(roots, .{});
        // macOS keeps each root's resolved path beside the path it was given.
        const extra_slots: u32 = if (is_darwin) options.max_roots else 0;
        const path_bytes: u32 = if (is_darwin) options.directory_path_bytes *| 2 else options.directory_path_bytes;
        var directories = try Directories.init(allocator, options.max_directories + extra_slots, path_bytes);
        errdefer directories.deinit(allocator);
        var pending = try Pending.init(allocator, options.max_pending, options.pending_path_bytes);
        errdefer pending.deinit(allocator);
        const scratch = try allocator.alloc(u8, 2 * (max_path_bytes + 1));
        errdefer allocator.free(scratch);
        const buffer_bytes = if (is_windows) @as(usize, options.native_buffer_bytes) * options.max_roots else options.native_buffer_bytes;
        const native_buffer = try allocator.alignedAlloc(u8, .@"8", buffer_bytes);
        errdefer allocator.free(native_buffer);
        const walk = try allocator.alloc(u32, if (is_linux) options.max_directories else 0);
        errdefer allocator.free(walk);
        var self: Watcher = .{
            .allocator = allocator,
            .thread = thread,
            .options = options,
            .roots = roots,
            .directories = directories,
            .pending = pending,
            .scratch = scratch,
            .native_buffer = native_buffer,
            .walk = walk,
            .descriptors = undefined,
            .inotify = undefined,
            .wake_fd = undefined,
            .wake_event = undefined,
            .run_loop = undefined,
            .run_mode = undefined,
            .wake_source = undefined,
            .woken = undefined,
        };
        if (is_linux) {
            self.descriptors = try DescriptorTable.init(allocator, options.max_directories);
            errdefer self.descriptors.deinit(allocator);
            const fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
            if (linux.errno(fd) != .SUCCESS) return errnoError(linux.errno(fd));
            self.inotify = @intCast(fd);
            errdefer _ = linux.close(self.inotify);
            const wake = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(wake) != .SUCCESS) return errnoError(linux.errno(wake));
            self.wake_fd = @intCast(wake);
        } else if (is_darwin) {
            self.woken = try allocator.create(bool);
            errdefer allocator.destroy(self.woken);
            self.woken.* = false;
            const mode_name = "ziggurat.watch";
            self.run_mode = cf.CFStringCreateWithBytes(null, mode_name, mode_name.len, cf.utf8, 0) orelse return error.SystemResources;
            errdefer cf.CFRelease(self.run_mode);
            var context: cf.SourceContext = .{ .info = self.woken, .perform = cf.performWake };
            self.wake_source = cf.CFRunLoopSourceCreate(null, 0, &context) orelse return error.SystemResources;
            self.run_loop = cf.CFRunLoopGetCurrent();
            cf.CFRunLoopAddSource(self.run_loop, self.wake_source, self.run_mode);
        } else {
            self.wake_event = win.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        }
        return self;
    }
    /// Cancels native reads, waits for their completion, closes every handle
    /// and frees init's buffers. Stop interrupting threads first. Idempotent.
    pub fn deinit(self: *Watcher) void {
        std.debug.assert(self.thread == std.Thread.getCurrentId());
        if (self.closed) return;
        for (self.roots, 0..) |root, index| if (root.state == .active) self.dropNative(@intCast(index));
        if (is_linux) {
            _ = linux.close(self.inotify);
            _ = linux.close(self.wake_fd);
            self.descriptors.deinit(self.allocator);
        } else if (is_darwin) {
            cf.CFRunLoopSourceInvalidate(self.wake_source);
            cf.CFRelease(self.wake_source);
            cf.CFRelease(self.run_mode);
            self.allocator.destroy(self.woken);
        } else _ = win.CloseHandle(self.wake_event);
        self.allocator.free(self.walk);
        self.allocator.free(self.native_buffer);
        self.allocator.free(self.scratch);
        self.pending.deinit(self.allocator);
        self.directories.deinit(self.allocator);
        self.allocator.free(self.roots);
        self.closed = true;
    }
    /// Thread-safe wake for a blocked or future wait. Repeated calls before
    /// that wait coalesce. Not valid once deinit has started.
    pub fn interrupt(self: *Watcher) void {
        if (is_linux) {
            const one: u64 = 1;
            _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
        } else if (is_windows) {
            _ = win.SetEvent(self.wake_event);
        } else if (is_darwin) {
            cf.CFRunLoopSourceSignal(self.wake_source);
            cf.CFRunLoopWakeUp(self.run_loop);
        }
    }
    fn require(self: *Watcher) !void {
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closed) return error.Closed;
    }
    fn lookup(self: *Watcher, root: Root) !u32 {
        if (root.index >= self.roots.len) return error.UnknownRoot;
        const state = &self.roots[root.index];
        if (state.state == .free or state.generation != root.generation) return error.UnknownRoot;
        return root.index;
    }
    fn id(self: *Watcher, index: u32) Root {
        return .{ .index = index, .generation = self.roots[index].generation };
    }

    /// Watches an absolute directory. Return means ready: native watches are
    /// established, and later changes under the root are reported. Changes
    /// before return are not, except that macOS can still deliver hints for
    /// writes made just before it, since fseventsd numbers events only as it
    /// receives them. The path is copied; reported paths begin with it
    /// unchanged (no canonicalization). Linux rejects overlapping roots.
    pub fn addRoot(self: *Watcher, path: []const u8) !Root {
        try self.require();
        self.last_failure = null;
        const trimmed = try rootPath(path);
        const index: u32 = for (self.roots, 0..) |root, at| {
            if (root.state == .free) break @intCast(at);
        } else return error.RootCapacityExceeded;
        const root = &self.roots[index];
        errdefer self.dropNative(index);
        if (is_linux) {
            const text = try join(self.scratch[0 .. max_path_bytes + 1], trimmed, "");
            root.directory = (try self.watchDirectory(index, text, true)) orelse return error.FileNotFound;
            if (self.options.recursive) try self.walkTree(index, root.directory, false);
        } else if (is_darwin) {
            root.directory = try self.directories.add(index, 0, trimmed);
            try self.openDarwin(index, trimmed);
        } else {
            root.directory = try self.directories.add(index, 0, trimmed);
            try self.openWindows(index, trimmed);
        }
        root.state = .active;
        root.overflow = null;
        root.incomplete = false;
        return self.id(index);
    }
    /// Stops watching and discards the root's undelivered events. A root whose
    /// root_removed event is still undelivered is released silently.
    pub fn removeRoot(self: *Watcher, root: Root) !void {
        try self.require();
        const index = try self.lookup(root);
        if (self.roots[index].state == .active) self.dropNative(index);
        self.pending.drop(0, index);
        self.release(index);
    }
    /// True after an incomplete_tree overflow: some subdirectories are not
    /// watched. Remove and re-add the root (e.g. with a larger budget).
    pub fn isIncomplete(self: *Watcher, root: Root) !bool {
        try self.require();
        return self.roots[try self.lookup(root)].incomplete;
    }

    /// Blocks this worker until a debounced batch is due, timeout_ms passes
    /// (null waits indefinitely) or interrupt is called. Events that do not fit
    /// in `events`/`path_storage` stay queued for the next wait; none are
    /// dropped. Returns ResultCapacityExceeded only when nothing fits.
    pub fn wait(self: *Watcher, events: []Event, path_storage: []u8, timeout_ms: ?u32) !Batch {
        try self.require();
        if (events.len == 0) return error.ResultCapacityExceeded;
        const start = monotonic();
        var polled = false;
        while (true) {
            const until_due = self.dueIn();
            if (until_due == 0) return self.deliver(events, path_storage, .batch);
            var limit = until_due;
            if (timeout_ms) |ms| {
                const total = @as(u64, ms) * std.time.ns_per_ms;
                const elapsed = if (start) |begin| if (monotonic()) |now| now.since(begin) else total else total;
                // An expired timeout still reads native events once without blocking.
                if (elapsed >= total and polled) return .{ .events = events[0..0], .wake = .timeout, .more = self.hasWork() };
                const left = total -| elapsed;
                limit = if (limit) |value| @min(value, left) else left;
            }
            polled = true;
            if (try self.block(limit)) {
                if (self.dueIn() == 0) return self.deliver(events, path_storage, .interrupted);
                return .{ .events = events[0..0], .wake = .interrupted, .more = self.hasWork() };
            }
        }
    }

    fn hasWork(self: *Watcher) bool {
        if (self.pending.count != 0) return true;
        for (self.roots) |root| if (root.state == .removed or (root.state == .active and root.overflow != null)) return true;
        return false;
    }
    /// Nanoseconds until the batch is due, 0 when due, null without work.
    fn dueIn(self: *Watcher) ?u64 {
        if (!self.hasWork()) {
            self.due = false;
            self.first = null;
            return null;
        }
        if (self.due) return 0;
        const now = monotonic() orelse return self.markDue();
        const first = self.first orelse return self.markDue();
        const last = self.last orelse return self.markDue();
        const quiet = now.since(last);
        const age = now.since(first);
        const debounce = @as(u64, self.options.debounce_ms) * std.time.ns_per_ms;
        const latency = @as(u64, self.options.max_latency_ms) * std.time.ns_per_ms;
        if (quiet >= debounce or age >= latency) return self.markDue();
        return @min(debounce - quiet, latency - age);
    }
    fn markDue(self: *Watcher) u64 {
        self.due = true;
        return 0;
    }
    fn activity(self: *Watcher) void {
        const now = monotonic();
        if (self.first == null) self.first = now;
        self.last = now;
    }
    fn deliver(self: *Watcher, events: []Event, storage: []u8, wake: Wake) !Batch {
        var count: usize = 0;
        var used: usize = 0;
        var taken: usize = 0;
        fill: {
            for (self.roots, 0..) |*root, at| {
                const index: u32 = @intCast(at);
                if (root.state == .removed) {
                    if (count == events.len) break :fill;
                    events[count] = .{ .root_removed = .{ .root = self.id(index) } };
                    count += 1;
                    self.release(index);
                    continue;
                }
                const reason = root.overflow orelse continue;
                if (root.state != .active) continue;
                if (count == events.len) break :fill;
                events[count] = .{ .overflow = .{ .root = self.id(index), .reason = reason } };
                count += 1;
                root.overflow = null;
            }
            while (taken < self.pending.count and count < events.len) : (taken += 1) {
                const entry = self.pending.entries[taken];
                const text = self.pending.path(entry);
                if (storage.len - used < text.len) {
                    if (count == 0) return error.ResultCapacityExceeded;
                    break;
                }
                @memcpy(storage[used..][0..text.len], text);
                events[count] = .{ .changed = .{ .root = self.id(entry.root), .path = storage[used..][0..text.len] } };
                used += text.len;
                count += 1;
            }
        }
        self.pending.drop(taken, null);
        const more = self.hasWork();
        if (!more) {
            self.due = false;
            self.first = null;
        }
        return .{ .events = events[0..count], .wake = wake, .more = more };
    }
    fn release(self: *Watcher, index: u32) void {
        const root = &self.roots[index];
        root.state = .free;
        root.overflow = null;
        root.incomplete = false;
        root.generation +%= 1;
    }
    fn changed(self: *Watcher, index: u32, path: []const u8) void {
        const root = &self.roots[index];
        if (root.state != .active or root.overflow != null) return;
        self.pending.add(index, path) catch return self.overflow(index, .pending_capacity);
        self.activity();
    }
    fn overflow(self: *Watcher, index: u32, reason: OverflowReason) void {
        const root = &self.roots[index];
        if (root.state != .active) return;
        if (reason == .incomplete_tree) root.incomplete = true;
        if (root.overflow == null or reason == .incomplete_tree) root.overflow = reason;
        self.pending.drop(0, index);
        self.activity();
    }
    fn rootLost(self: *Watcher, index: u32) void {
        const root = &self.roots[index];
        if (root.state != .active) return;
        self.dropNative(index);
        root.state = .removed;
        root.overflow = null;
        self.pending.drop(0, index);
        self.activity();
    }
    /// Releases the root's native watches and directory slots.
    fn dropNative(self: *Watcher, index: u32) void {
        if (is_linux) {
            for (self.directories.slots, 0..) |slot, at| {
                if (!slot.live or slot.root != index) continue;
                _ = linux.inotify_rm_watch(self.inotify, slot.wd);
                self.forget(@intCast(at));
            }
        } else if (is_windows) {
            const native = &self.roots[index].native;
            if (native.handle) |handle| {
                if (native.reading) {
                    var bytes: win.DWORD = 0;
                    _ = win.CancelIoEx(handle, &native.overlapped);
                    _ = win.GetOverlappedResult(handle, &native.overlapped, &bytes, 1);
                }
                _ = win.CloseHandle(handle);
            }
            if (native.overlapped.hEvent) |event| _ = win.CloseHandle(event);
            native.* = .{};
            for (self.directories.slots, 0..) |slot, at| {
                if (slot.live and slot.root == index) self.directories.release(@intCast(at));
            }
        } else if (is_darwin) {
            const native = &self.roots[index].native;
            if (native.stream) |stream| {
                cf.FSEventStreamStop(stream);
                cf.FSEventStreamInvalidate(stream);
                cf.FSEventStreamRelease(stream);
            }
            native.* = .{};
            for (self.directories.slots, 0..) |slot, at| {
                if (slot.live and slot.root == index) self.directories.release(@intCast(at));
            }
        }
    }

    /// Returns true when interrupted. Native events are processed first.
    fn block(self: *Watcher, limit_ns: ?u64) !bool {
        if (is_linux) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.inotify, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ms: i32 = if (limit_ns) |ns| @intCast(@min(std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable, std.math.maxInt(i32))) else -1;
            _ = try std.posix.poll(&fds, ms);
            if (fds[0].revents != 0) try self.readLinux();
            if (fds[1].revents != 0) {
                var value: u64 = 0;
                _ = linux.read(self.wake_fd, std.mem.asBytes(&value), @sizeOf(u64));
                return true;
            }
            return false;
        } else if (is_darwin) {
            // Both callbacks stop this run, so it returns once anything was handled.
            const seconds: f64 = if (limit_ns) |ns| @as(f64, @floatFromInt(ns)) / std.time.ns_per_s else 1.0e10;
            self.in_run = true;
            _ = cf.CFRunLoopRunInMode(self.run_mode, seconds, 1);
            self.in_run = false;
            if (!self.woken.*) return false;
            self.woken.* = false;
            return true;
        } else {
            var handles: [64]win.HANDLE = undefined;
            var owners: [64]u32 = undefined;
            handles[0] = self.wake_event;
            var count: usize = 1;
            for (self.roots, 0..) |root, at| {
                if (root.state != .active or !root.native.reading) continue;
                handles[count] = root.native.overlapped.hEvent;
                owners[count] = @intCast(at);
                count += 1;
            }
            const ms: win.DWORD = if (limit_ns) |ns| @intCast(@min(std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable, win.INFINITE - 1)) else win.INFINITE;
            const result = win.WaitForMultipleObjects(@intCast(count), &handles, 0, ms);
            if (result == win.WAIT_TIMEOUT) return false;
            if (result == win.WAIT_FAILED or result >= win.WAIT_OBJECT_0 + count) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.WatchWaitFailed;
            }
            // Drain every signaled root so a busy low index cannot starve others.
            for (1..count) |at| {
                if (win.WaitForSingleObject(handles[at], 0) == win.WAIT_OBJECT_0) self.completeWindows(owners[at]);
            }
            if (win.WaitForSingleObject(self.wake_event, 0) == win.WAIT_OBJECT_0) {
                _ = win.ResetEvent(self.wake_event);
                return true;
            }
            return false;
        }
    }

    // Linux inotify.
    const watch_mask: u32 = if (is_linux) linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK else 0;
    fn readLinux(self: *Watcher) !void {
        const rc = linux.read(self.inotify, self.native_buffer.ptr, self.native_buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN, .INTR => return,
            else => |code| {
                self.last_failure = .{ .domain = .errno, .code = @backingInt(code) };
                return error.WatchReadFailed;
            },
        }
        const header = @sizeOf(linux.inotify_event);
        var offset: usize = 0;
        while (offset + header <= rc) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(self.native_buffer[offset..].ptr));
            const name = std.mem.sliceTo(self.native_buffer[offset + header ..][0..event.len], 0);
            offset += header + event.len;
            self.inotifyEvent(event.wd, event.mask, name);
        }
    }
    fn inotifyEvent(self: *Watcher, wd: i32, mask: u32, name: []const u8) void {
        if (mask & linux.IN.Q_OVERFLOW != 0) {
            for (0..self.roots.len) |index| self.overflow(@intCast(index), .native_queue);
            return;
        }
        const slot = self.descriptors.get(wd) orelse return;
        const index = self.directories.slots[slot].root;
        if (mask & (linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.UNMOUNT) != 0) {
            if (self.roots[index].directory == slot) {
                self.rootLost(index);
            } else if (mask & linux.IN.IGNORED != 0) self.forget(slot);
            return;
        }
        const parent = self.scratch[0 .. max_path_bytes + 1];
        const directory = join(parent, self.directories.path(slot), "") catch unreachable;
        self.changed(index, directory);
        if (!self.options.recursive or mask & linux.IN.ISDIR == 0 or name.len == 0) return;
        const child = join(parent, directory, name) catch return self.overflow(index, .incomplete_tree);
        if (mask & linux.IN.MOVED_FROM != 0) self.forgetTree(index, child);
        if (mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
            const added = self.watchDirectory(index, child, false) catch return self.overflow(index, .incomplete_tree);
            if (added) |at| {
                self.changed(index, child);
                // Runtime walk failures keep the root but mark it incomplete.
                self.walkTree(index, at, true) catch self.overflow(index, .incomplete_tree);
            }
        }
    }
    /// Adds an inotify watch. null when the directory vanished or this root
    /// already watches the inode (bind-mount loops).
    fn watchDirectory(self: *Watcher, index: u32, path: [:0]const u8, top: bool) !?u32 {
        const mask = if (top) watch_mask else watch_mask | linux.IN.DONT_FOLLOW;
        const rc = linux.inotify_add_watch(self.inotify, path.ptr, mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT, .NOTDIR, .LOOP => return if (top) errnoError(linux.errno(rc)) else null,
            else => |code| {
                self.last_failure = .{ .domain = .errno, .code = @backingInt(code) };
                return errnoError(code);
            },
        }
        const wd: i32 = @intCast(rc);
        if (self.descriptors.get(wd)) |existing| {
            if (self.directories.slots[existing].root != index) return error.OverlappingRoot;
            return null;
        }
        const slot = self.directories.add(index, wd, path) catch |err| {
            _ = linux.inotify_rm_watch(self.inotify, wd);
            return err;
        };
        self.descriptors.put(wd, slot);
        return slot;
    }
    /// Depth-first walk below `start` without following symlinks. Each new
    /// directory is watched before it is listed.
    fn walkTree(self: *Watcher, index: u32, start: u32, report: bool) !void {
        const parent = self.scratch[0 .. max_path_bytes + 1];
        const child = self.scratch[max_path_bytes + 1 ..];
        self.walk[0] = start;
        var depth: usize = 1;
        while (depth > 0) {
            depth -= 1;
            const slot = self.walk[depth];
            if (!self.directories.slots[slot].live) continue;
            const directory = try join(parent, self.directories.path(slot), "");
            var dir = std.Io.Dir.openDirAbsolute(zio.io(), directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
                else => return err,
            };
            defer dir.close(zio.io());
            var entries = dir.iterate();
            while (try entries.next(zio.io())) |entry| {
                if (entry.kind != .directory and entry.kind != .unknown) continue;
                const path = try join(child, directory, entry.name);
                const added = (try self.watchDirectory(index, path, false)) orelse continue;
                if (report) self.changed(index, path);
                self.walk[depth] = added;
                depth += 1;
            }
        }
    }
    fn forget(self: *Watcher, slot: u32) void {
        if (is_linux) self.descriptors.remove(self.directories.slots[slot].wd);
        self.directories.release(slot);
    }
    fn forgetTree(self: *Watcher, index: u32, prefix: []const u8) void {
        for (self.directories.slots, 0..) |slot, at| {
            if (!slot.live or slot.root != index or self.roots[index].directory == at) continue;
            const path = self.directories.path(@intCast(at));
            if (!std.mem.startsWith(u8, path, prefix)) continue;
            if (path.len != prefix.len and path[prefix.len] != '/') continue;
            _ = linux.inotify_rm_watch(self.inotify, slot.wd);
            self.forget(@intCast(at));
        }
    }

    // Windows ReadDirectoryChangesW.
    const notify_filter: u32 = if (is_windows) win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_ATTRIBUTES | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_CREATION else 0;
    fn openWindows(self: *Watcher, index: u32, path: []const u8) !void {
        const native = &self.roots[index].native;
        var wide: [32768]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return error.InvalidUtf8;
        wide[length] = 0;
        native.overlapped.hEvent = win.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        const handle = win.CreateFileW(&wide, win.FILE_LIST_DIRECTORY, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED, null);
        if (handle == null or @intFromPtr(handle) == std.math.maxInt(usize)) {
            const code = win.GetLastError();
            self.last_failure = .{ .domain = .win32, .code = code };
            return switch (code) {
                win.ERROR_FILE_NOT_FOUND, win.ERROR_PATH_NOT_FOUND => error.FileNotFound,
                win.ERROR_ACCESS_DENIED => error.AccessDenied,
                win.ERROR_DIRECTORY => error.NotDir,
                else => error.WatchFailed,
            };
        }
        native.handle = handle;
        if (!self.issueWindows(index)) return switch (self.last_failure.?.code) {
            win.ERROR_INVALID_PARAMETER, win.ERROR_DIRECTORY, win.ERROR_INVALID_FUNCTION => error.NotDir,
            win.ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.WatchFailed,
        };
    }
    fn windowsBuffer(self: *Watcher, index: u32) []align(8) u8 {
        const size = self.options.native_buffer_bytes;
        return @alignCast(self.native_buffer[index * size ..][0..size]);
    }
    fn issueWindows(self: *Watcher, index: u32) bool {
        const native = &self.roots[index].native;
        const event = native.overlapped.hEvent;
        _ = win.ResetEvent(event);
        native.overlapped = std.mem.zeroes(win.OVERLAPPED);
        native.overlapped.hEvent = event;
        const buffer = self.windowsBuffer(index);
        if (win.ReadDirectoryChangesW(native.handle, buffer.ptr, @intCast(buffer.len), @intFromBool(self.options.recursive), notify_filter, null, &native.overlapped, null) == 0) {
            self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
            return false;
        }
        native.reading = true;
        return true;
    }
    fn completeWindows(self: *Watcher, index: u32) void {
        const native = &self.roots[index].native;
        var bytes: win.DWORD = 0;
        const ok = win.GetOverlappedResult(native.handle, &native.overlapped, &bytes, 0) != 0;
        native.reading = false;
        if (!ok) {
            const code = win.GetLastError();
            if (code != win.ERROR_NOTIFY_ENUM_DIR) {
                self.last_failure = .{ .domain = .win32, .code = code };
                return self.rootLost(index);
            }
            self.overflow(index, .native_queue);
        } else if (bytes == 0) {
            var info: win.FILE_STANDARD_INFO = undefined;
            if (win.GetFileInformationByHandleEx(native.handle, win.FileStandardInfo, &info, @sizeOf(win.FILE_STANDARD_INFO)) != 0 and info.DeletePending != 0) return self.rootLost(index);
            self.overflow(index, .native_queue);
        } else self.parseWindows(index, self.windowsBuffer(index)[0..bytes]);
        if (!self.issueWindows(index)) self.rootLost(index);
    }
    fn parseWindows(self: *Watcher, index: u32, buffer: []align(8) const u8) void {
        const root = self.directories.path(self.roots[index].directory);
        const destination = self.scratch;
        @memcpy(destination[0..root.len], root);
        var offset: usize = 0;
        while (offset + @sizeOf(win.FILE_NOTIFY_INFORMATION) <= buffer.len) {
            const info: *const win.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(buffer[offset..].ptr));
            const units: [*]const u16 = @ptrCast(&info.FileName);
            const name = units[0 .. info.FileNameLength / 2];
            const separator = std.mem.lastIndexOfScalar(u16, name, '\\');
            var length = root.len;
            if (separator) |at| {
                if (length == 0 or destination[length - 1] != '\\') {
                    destination[length] = '\\';
                    length += 1;
                }
                length += std.unicode.wtf16LeToWtf8(destination[length..], name[0..at]);
            }
            self.changed(index, destination[0..length]);
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }

    // macOS FSEvents, one stream per root on this thread's run loop.
    fn openDarwin(self: *Watcher, index: u32, path: []const u8) !void {
        const native = &self.roots[index].native;
        const text = try join(self.scratch[0 .. max_path_bytes + 1], path, "");
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, text.ptr, &st, 0) != 0) return self.darwinErrno();
        if (st.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.NotDir;
        native.device = st.dev;
        native.inode = st.ino;
        var resolved: [std.c.PATH_MAX]u8 = undefined;
        const real = std.c.realpath(text.ptr, &resolved) orelse return self.darwinErrno();
        native.canonical = try self.directories.add(index, 0, try rootPath(std.mem.span(real)));
        const canonical = self.directories.path(native.canonical);
        const string = cf.CFStringCreateWithBytes(null, canonical.ptr, @intCast(canonical.len), cf.utf8, 0) orelse return error.SystemResources;
        defer cf.CFRelease(string);
        const values = [_]?*const anyopaque{string};
        const paths = cf.CFArrayCreate(null, &values, 1, null) orelse return error.SystemResources;
        defer cf.CFRelease(paths);
        var context: cf.StreamContext = .{ .info = self };
        const stream = cf.FSEventStreamCreate(null, onDarwinEvents, &context, paths, cf.since_now, 0.0, cf.create_no_defer | cf.create_watch_root) orelse return error.WatchFailed;
        native.stream = stream;
        cf.FSEventStreamScheduleWithRunLoop(stream, self.run_loop, self.run_mode);
        if (cf.FSEventStreamStart(stream) == 0) return error.WatchFailed;
        // Writes made just before the stream started can still be queued in
        // fseventsd; flushing delivers them now so they are not reported.
        self.priming = true;
        cf.FSEventStreamFlushSync(stream);
        self.priming = false;
    }
    fn darwinErrno(self: *Watcher) anyerror {
        const code = std.c.errno(-1);
        self.last_failure = .{ .domain = .errno, .code = @intCast(@backingInt(code)) };
        return switch (code) {
            .ACCES, .PERM => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .MFILE, .NFILE => error.ProcessFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => error.Unexpected,
        };
    }
    fn onDarwinEvents(stream: ?*const anyopaque, info: ?*anyopaque, count: usize, paths: ?*anyopaque, flags: [*]const u32, ids: [*]const u64) callconv(.c) void {
        _ = ids;
        const self: *Watcher = @ptrCast(@alignCast(info.?));
        if (self.in_run) cf.CFRunLoopStop(cf.CFRunLoopGetCurrent());
        if (self.priming) return;
        const index: u32 = for (self.roots, 0..) |root, at| {
            if (root.state == .active and root.native.stream != null and @intFromPtr(root.native.stream.?) == @intFromPtr(stream)) break @intCast(at);
        } else return;
        const list: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths.?));
        for (0..count) |at| self.darwinEvent(index, std.mem.span(list[at]), flags[at]);
    }
    fn darwinEvent(self: *Watcher, index: u32, reported: []const u8, flags: u32) void {
        const root = &self.roots[index];
        if (root.state != .active) return;
        if (flags & cf.event_root_changed != 0) {
            const text = join(self.scratch[0 .. max_path_bytes + 1], self.directories.path(root.directory), "") catch unreachable;
            var st: std.c.Stat = undefined;
            const same = std.c.fstatat(std.c.AT.FDCWD, text.ptr, &st, 0) == 0 and st.mode & std.c.S.IFMT == std.c.S.IFDIR and st.dev == root.native.device and st.ino == root.native.inode;
            if (!same) self.rootLost(index);
            return;
        }
        if (flags & (cf.event_must_scan_subdirs | cf.event_user_dropped | cf.event_kernel_dropped) != 0) return self.overflow(index, .native_queue);
        if (flags & cf.event_unmount != 0) return;
        var path = reported;
        while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        const canonical = self.directories.path(root.native.canonical);
        if (!std.mem.startsWith(u8, path, canonical)) return;
        var rest = path[canonical.len..];
        if (canonical.len == 1) {
            rest = if (path.len == 1) "" else path;
        } else if (rest.len != 0 and rest[0] != '/') return;
        if (!self.options.recursive and rest.len != 0) return;
        const given = self.directories.path(root.directory);
        const destination = self.scratch[0 .. max_path_bytes + 1];
        @memcpy(destination[0..given.len], given);
        // A root of "/" already ends with the separator `rest` begins with.
        const skip: usize = if (rest.len != 0 and given.len != 0 and given[given.len - 1] == '/') 1 else 0;
        const tail = rest[skip..];
        if (given.len + tail.len > max_path_bytes) return self.overflow(index, .incomplete_tree);
        @memcpy(destination[given.len..][0..tail.len], tail);
        self.changed(index, destination[0 .. given.len + tail.len]);
    }
};

/// CoreFoundation and FSEvents (CoreServices) declarations for macOS.
const cf = if (is_darwin) struct {
    const Ref = *anyopaque;
    const utf8: u32 = 0x08000100;
    const since_now: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const create_no_defer: u32 = 0x02;
    const create_watch_root: u32 = 0x04;
    const event_must_scan_subdirs: u32 = 0x01;
    const event_user_dropped: u32 = 0x02;
    const event_kernel_dropped: u32 = 0x04;
    const event_root_changed: u32 = 0x20;
    const event_unmount: u32 = 0x80;
    const SourceContext = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
        equal: ?*const anyopaque = null,
        hash: ?*const anyopaque = null,
        schedule: ?*const anyopaque = null,
        cancel: ?*const anyopaque = null,
        perform: ?*const fn (?*anyopaque) callconv(.c) void,
    };
    const StreamContext = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };
    const StreamCallback = fn (?*const anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;
    fn performWake(info: ?*anyopaque) callconv(.c) void {
        const woken: *bool = @ptrCast(@alignCast(info.?));
        woken.* = true;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    extern fn CFRelease(ref: *const anyopaque) void;
    extern fn CFStringCreateWithBytes(allocator: ?Ref, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?Ref;
    extern fn CFArrayCreate(allocator: ?Ref, values: [*]const ?*const anyopaque, count: isize, callbacks: ?*const anyopaque) ?Ref;
    extern fn CFRunLoopGetCurrent() Ref;
    extern fn CFRunLoopRunInMode(mode: Ref, seconds: f64, return_after_source_handled: u8) i32;
    extern fn CFRunLoopStop(run_loop: Ref) void;
    extern fn CFRunLoopWakeUp(run_loop: Ref) void;
    extern fn CFRunLoopSourceCreate(allocator: ?Ref, order: isize, context: *SourceContext) ?Ref;
    extern fn CFRunLoopAddSource(run_loop: Ref, source: Ref, mode: Ref) void;
    extern fn CFRunLoopSourceSignal(source: Ref) void;
    extern fn CFRunLoopSourceInvalidate(source: Ref) void;
    extern fn FSEventStreamCreate(allocator: ?Ref, callback: *const StreamCallback, context: *StreamContext, paths: Ref, since: u64, latency: f64, flags: u32) ?Ref;
    extern fn FSEventStreamScheduleWithRunLoop(stream: Ref, run_loop: Ref, mode: Ref) void;
    extern fn FSEventStreamStart(stream: Ref) u8;
    extern fn FSEventStreamStop(stream: Ref) void;
    extern fn FSEventStreamFlushSync(stream: Ref) void;
    extern fn FSEventStreamInvalidate(stream: Ref) void;
    extern fn FSEventStreamRelease(stream: Ref) void;
} else struct {
    const Ref = *anyopaque;
};

fn validate(options: Options) !void {
    if (options.max_roots == 0 or options.max_roots > max_roots_limit) return error.InvalidOptions;
    if (options.max_directories < options.max_roots or options.max_pending == 0) return error.InvalidOptions;
    if (options.debounce_ms > options.max_latency_ms) return error.InvalidOptions;
    if (options.native_buffer_bytes < 4096 or options.native_buffer_bytes > 1024 * 1024 or options.native_buffer_bytes % 8 != 0) return error.InvalidOptions;
    if (options.directory_path_bytes == 0 or options.pending_path_bytes == 0) return error.InvalidOptions;
}
fn monotonic() ?zio.Instant {
    return zio.Instant.now() catch null;
}
fn errnoError(code: linux.E) anyerror {
    return switch (code) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.WatchLimitReached,
        .MFILE, .NFILE => error.ProcessFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}
fn isSeparator(value: u8) bool {
    return value == '/' or (is_windows and value == '\\');
}
/// Validates an absolute root and strips trailing separators except the
/// filesystem root itself.
fn rootPath(path: []const u8) ![]const u8 {
    if (path.len > max_path_bytes) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    const minimum: usize = if (is_windows) blk: {
        if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSeparator(path[2])) break :blk 3;
        if (path.len >= 5 and isSeparator(path[0]) and isSeparator(path[1]) and path[2] != '?' and path[2] != '.') {
            const server = std.mem.indexOfAnyPos(u8, path, 2, "\\/") orelse return error.AbsolutePathRequired;
            if (server == 2 or server + 1 >= path.len or isSeparator(path[server + 1])) return error.AbsolutePathRequired;
            break :blk server + 2;
        }
        return error.AbsolutePathRequired;
    } else blk: {
        if (path.len == 0 or path[0] != '/') return error.AbsolutePathRequired;
        break :blk 1;
    };
    var end = path.len;
    while (end > minimum and isSeparator(path[end - 1])) end -= 1;
    return path[0..end];
}
/// Writes `parent` (+ '/' + `name`) with a NUL terminator into `destination`.
/// `parent` may alias the start of `destination`.
fn join(destination: []u8, parent: []const u8, name: []const u8) ![:0]u8 {
    const glue = name.len != 0 and !(parent.len != 0 and isSeparator(parent[parent.len - 1]));
    const length = parent.len + @intFromBool(glue) + name.len;
    if (length > max_path_bytes or length + 1 > destination.len) return error.NameTooLong;
    if (parent.ptr != destination.ptr) std.mem.copyForwards(u8, destination[0..parent.len], parent);
    if (glue) destination[parent.len] = if (is_windows) '\\' else '/';
    @memcpy(destination[length - name.len .. length], name);
    destination[length] = 0;
    return destination[0..length :0];
}

/// Undelivered changed directories in FIFO order, coalesced by (root, path).
const Pending = struct {
    entries: []Entry,
    count: usize = 0,
    bytes: []u8,
    used: usize = 0,
    const Entry = struct { root: u32, offset: u32, len: u32 };
    fn init(allocator: std.mem.Allocator, entries: u32, bytes: u32) !Pending {
        const list = try allocator.alloc(Entry, entries);
        errdefer allocator.free(list);
        return .{ .entries = list, .bytes = try allocator.alloc(u8, bytes) };
    }
    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.entries);
    }
    fn path(self: *const Pending, entry: Entry) []const u8 {
        return self.bytes[entry.offset..][0..entry.len];
    }
    fn add(self: *Pending, root: u32, text: []const u8) error{Full}!void {
        for (self.entries[0..self.count]) |entry| {
            if (entry.root == root and std.mem.eql(u8, self.path(entry), text)) return;
        }
        if (self.count == self.entries.len or self.bytes.len - self.used < text.len) return error.Full;
        @memcpy(self.bytes[self.used..][0..text.len], text);
        self.entries[self.count] = .{ .root = root, .offset = @intCast(self.used), .len = @intCast(text.len) };
        self.count += 1;
        self.used += text.len;
    }
    /// Removes the first `prefix` entries and every entry of `root`, keeping
    /// FIFO order and compacting the path bytes.
    fn drop(self: *Pending, prefix: usize, root: ?u32) void {
        var kept: usize = 0;
        var used: usize = 0;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (index < prefix) continue;
            if (root) |value| if (entry.root == value) continue;
            std.mem.copyForwards(u8, self.bytes[used..][0..entry.len], self.path(entry));
            self.entries[kept] = .{ .root = entry.root, .offset = @intCast(used), .len = entry.len };
            kept += 1;
            used += entry.len;
        }
        self.count = kept;
        self.used = used;
    }
};

/// Watched directory slots with full paths in a compacting byte pool.
const Directories = struct {
    slots: []Slot,
    free: []u32,
    free_count: usize,
    bytes: []u8,
    spare: []u8,
    used: usize = 0,
    dead: usize = 0,
    const Slot = struct { root: u32 = 0, wd: i32 = -1, offset: u32 = 0, len: u32 = 0, live: bool = false };
    fn init(allocator: std.mem.Allocator, capacity: u32, bytes: u32) !Directories {
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const free = try allocator.alloc(u32, capacity);
        errdefer allocator.free(free);
        for (free, 0..) |*value, index| value.* = @intCast(capacity - 1 - index);
        const pool = try allocator.alloc(u8, bytes);
        errdefer allocator.free(pool);
        return .{ .slots = slots, .free = free, .free_count = capacity, .bytes = pool, .spare = try allocator.alloc(u8, bytes) };
    }
    fn deinit(self: *Directories, allocator: std.mem.Allocator) void {
        allocator.free(self.spare);
        allocator.free(self.bytes);
        allocator.free(self.free);
        allocator.free(self.slots);
    }
    fn path(self: *const Directories, index: u32) []const u8 {
        const slot = self.slots[index];
        return self.bytes[slot.offset..][0..slot.len];
    }
    fn add(self: *Directories, root: u32, wd: i32, text: []const u8) error{DirectoryBudgetExceeded}!u32 {
        if (self.free_count == 0) return error.DirectoryBudgetExceeded;
        if (self.bytes.len - self.used < text.len) {
            if (self.bytes.len - self.used + self.dead < text.len) return error.DirectoryBudgetExceeded;
            self.compact();
        }
        self.free_count -= 1;
        const index = self.free[self.free_count];
        @memcpy(self.bytes[self.used..][0..text.len], text);
        self.slots[index] = .{ .root = root, .wd = wd, .offset = @intCast(self.used), .len = @intCast(text.len), .live = true };
        self.used += text.len;
        return index;
    }
    fn release(self: *Directories, index: u32) void {
        const slot = &self.slots[index];
        if (!slot.live) return;
        slot.live = false;
        self.dead += slot.len;
        self.free[self.free_count] = index;
        self.free_count += 1;
    }
    fn compact(self: *Directories) void {
        var used: usize = 0;
        for (self.slots) |*slot| {
            if (!slot.live) continue;
            @memcpy(self.spare[used..][0..slot.len], self.bytes[slot.offset..][0..slot.len]);
            slot.offset = @intCast(used);
            used += slot.len;
        }
        std.mem.swap([]u8, &self.bytes, &self.spare);
        self.used = used;
        self.dead = 0;
    }
};

/// inotify watch descriptor to slot: linear probing with backward-shift
/// deletion, so churn leaves no tombstones. Sized to twice the budget.
const DescriptorTable = struct {
    keys: []i32,
    values: []u32,
    const empty: i32 = -1;
    fn init(allocator: std.mem.Allocator, capacity: u32) !DescriptorTable {
        const size = try std.math.ceilPowerOfTwo(usize, @max(@as(usize, capacity) * 2, 2));
        const keys = try allocator.alloc(i32, size);
        errdefer allocator.free(keys);
        @memset(keys, empty);
        return .{ .keys = keys, .values = try allocator.alloc(u32, size) };
    }
    fn deinit(self: *DescriptorTable, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        allocator.free(self.keys);
    }
    fn home(self: *const DescriptorTable, key: i32) usize {
        const mixed = @as(u32, @bitCast(key)) *% 0x9e3779b1;
        return mixed & (self.keys.len - 1);
    }
    fn get(self: *const DescriptorTable, key: i32) ?u32 {
        var at = self.home(key);
        while (self.keys[at] != empty) : (at = (at + 1) & (self.keys.len - 1)) {
            if (self.keys[at] == key) return self.values[at];
        }
        return null;
    }
    /// The caller keeps the live count at or below half the table.
    fn put(self: *DescriptorTable, key: i32, value: u32) void {
        var at = self.home(key);
        while (self.keys[at] != empty and self.keys[at] != key) at = (at + 1) & (self.keys.len - 1);
        self.keys[at] = key;
        self.values[at] = value;
    }
    fn remove(self: *DescriptorTable, key: i32) void {
        const mask = self.keys.len - 1;
        var hole = self.home(key);
        while (self.keys[hole] != key) : (hole = (hole + 1) & mask) {
            if (self.keys[hole] == empty) return;
        }
        var next = (hole + 1) & mask;
        while (self.keys[next] != empty) : (next = (next + 1) & mask) {
            const ideal = self.home(self.keys[next]);
            // Move `next` into the hole when its probe path passes the hole.
            if ((next -% ideal) & mask >= (next -% hole) & mask) {
                self.keys[hole] = self.keys[next];
                self.values[hole] = self.values[next];
                hole = next;
            }
        }
        self.keys[hole] = empty;
    }
};

test "pending batches coalesce per root, keep FIFO order and report fullness" {
    var pending = try Pending.init(std.testing.allocator, 3, 16);
    defer pending.deinit(std.testing.allocator);
    try pending.add(0, "/a");
    try pending.add(1, "/a");
    try pending.add(0, "/a");
    try pending.add(0, "/bb");
    try std.testing.expectEqual(@as(usize, 3), pending.count);
    try std.testing.expectError(error.Full, pending.add(0, "/c"));
    pending.drop(1, null);
    try std.testing.expectEqualStrings("/a", pending.path(pending.entries[0]));
    try std.testing.expectEqual(@as(u32, 1), pending.entries[0].root);
    try std.testing.expectEqualStrings("/bb", pending.path(pending.entries[1]));
    pending.drop(0, 1);
    try std.testing.expectEqual(@as(usize, 1), pending.count);
    try std.testing.expectEqualStrings("/bb", pending.path(pending.entries[0]));
    try std.testing.expectEqual(@as(usize, 3), pending.used);
    try pending.add(2, "0123456789abc");
    try std.testing.expectError(error.Full, pending.add(2, "x"));
}

test "directory pool compacts released paths and enforces its budget" {
    var directories = try Directories.init(std.testing.allocator, 3, 8);
    defer directories.deinit(std.testing.allocator);
    const a = try directories.add(0, 1, "/aaa");
    const b = try directories.add(0, 2, "/bb");
    try std.testing.expectError(error.DirectoryBudgetExceeded, directories.add(0, 3, "/cc"));
    directories.release(a);
    const c = try directories.add(0, 3, "/cccc");
    try std.testing.expectEqualStrings("/bb", directories.path(b));
    try std.testing.expectEqualStrings("/cccc", directories.path(c));
    _ = try directories.add(0, 4, "");
    try std.testing.expectError(error.DirectoryBudgetExceeded, directories.add(0, 5, ""));
}

test "descriptor table survives removal churn without tombstones" {
    var table = try DescriptorTable.init(std.testing.allocator, 8);
    defer table.deinit(std.testing.allocator);
    var key: i32 = 1;
    for (0..2000) |round| {
        table.put(key, @intCast(round));
        table.put(key + 16, 7);
        try std.testing.expectEqual(@as(?u32, @intCast(round)), table.get(key));
        table.remove(key);
        try std.testing.expectEqual(@as(?u32, null), table.get(key));
        try std.testing.expectEqual(@as(?u32, 7), table.get(key + 16));
        table.remove(key + 16);
        key += 3;
    }
    for (table.keys) |value| try std.testing.expectEqual(DescriptorTable.empty, value);
}

test "root paths are absolute and joins are bounded" {
    if (is_windows) {
        try std.testing.expectEqualStrings("C:\\", try rootPath("C:\\\\"));
        try std.testing.expectEqualStrings("C:\\work", try rootPath("C:\\work\\"));
        try std.testing.expectError(error.AbsolutePathRequired, rootPath("\\work"));
    } else {
        try std.testing.expectEqualStrings("/", try rootPath("//"));
        try std.testing.expectEqualStrings("/work", try rootPath("/work//"));
        try std.testing.expectError(error.AbsolutePathRequired, rootPath("work"));
    }
    try std.testing.expectError(error.EmbeddedNul, rootPath("/a\x00b"));
    var buffer: [16]u8 = undefined;
    const sep = if (is_windows) "\\" else "/";
    try std.testing.expectEqualStrings(sep ++ "name", try join(&buffer, sep, "name"));
    try std.testing.expectEqualStrings("/a" ++ sep ++ "b", try join(&buffer, "/a", "b"));
    try std.testing.expectError(error.NameTooLong, join(&buffer, "/0123456789", "abcdef"));
    try std.testing.expectError(error.UiThreadForbidden, Watcher.init(std.testing.allocator, std.Thread.getCurrentId(), .{}));
    try std.testing.expectError(error.InvalidOptions, validate(.{ .debounce_ms = 10, .max_latency_ms = 5 }));
}
