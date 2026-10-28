//! Watch plugin: pages follow changes to the directories and files the app
//! names, through `@ziggurat/plugin-watch`. Each watch runs on a worker the
//! plugin starts for it and joins once it ends: the worker waits on the
//! system watcher, looks again at what changed and compares it with what it
//! saw, and hands the differences to the main thread through `App.post`.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const ipc = @import("ziggurat_ipc");
const runtime = @import("ziggurat_page_runtime");
const system_watch = @import("ziggurat_system_watch");
pub const scan = @import("watch_scan.zig");

pub const Service = @import("watch_service.zig").Service;
const limits = Service.limits;
const Dispatcher = ipc.Dispatcher(Service, Implementation, Plugin, limits);
const Work = ipc.Work(Service, limits, "watch");
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;
const is_windows = builtin.os.tag == .windows;
const separator = if (is_windows) '\\' else '/';

/// The JSON of one part stays under this; a batch beyond it is split.
const part_bytes = 48 * 1024;

pub const Ignore = scan.Ignore;

/// A directory, or a file, pages may watch by its name.
pub const Root = struct {
    /// 1–64 bytes of lowercase ASCII letters, digits and `-`, starting with
    /// a letter.
    name: []const u8,
    /// Absolute; its symlinks are resolved when the plugin starts.
    path: []const u8,
    /// Lets pages watch the directories in it too, and what is in them.
    recursive: bool = false,
    ignore: ?Ignore = null,
};

/// A watch a page asks for.
pub const Request = struct {
    root: []const u8,
    /// Relative to the root, separated by slashes: "." for the root itself.
    path: []const u8,
    recursive: bool,
};

/// Main thread: the root of a name not among `Options.roots`, such as a
/// folder the user chose, or null. The root's strings are copied.
pub const Resolve = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, name: []const u8) ?Root,
};

/// Main thread: whether the page may start a watch.
pub const Allow = struct {
    context: *anyopaque,
    allow: *const fn (*anyopaque, Request) bool,
};

/// Bounds the watches of every plugin that shares it; any thread.
pub const Quota = struct {
    max: u32 = 128,
    mutex: zio.Mutex = .{},
    used: u32 = 0,

    fn take(self: *Quota) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.used >= self.max) return false;
        self.used += 1;
        return true;
    }

    fn give(self: *Quota) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.used -= 1;
    }
};

pub const Options = struct {
    post: runtime.Post,
    roots: []const Root = &.{},
    resolve: ?Resolve = null,
    allow: ?Allow = null,
    /// Shared by the plugins of every page so that all of them watch at most
    /// `Quota.max`; each page watches at most 8 regardless.
    quota: ?*Quota = null,
    /// Files and directories one watch keeps a snapshot of before it stops
    /// with `limit`. Ignored entries do not count.
    max_entries: u32 = 8192,
    /// Directories one recursive watch has the system watch (Linux).
    max_directories: u32 = 8192,
};

const Owned = struct {
    name: []u8,
    path: []u8,
    recursive: bool,
    ignore: ?Ignore,
    /// A directory root's identity when the plugin started: one replaced
    /// since is another directory.
    identity: ?scan.Id,
};

const Watch = struct {
    // Main thread.
    live: bool = false,
    work: Work = undefined,
    ready_sent: bool = false,
    parts_sent: usize = 0,
    /// Chunks sent and the last the page acknowledged: a failure waits for
    /// the page to take the batches before it, which an error would drop.
    chunks: u32 = 0,
    acked: u32 = 0,
    quota: bool = false,
    thread: ?std.Thread = null,
    // Written before the worker starts.
    target: []u8 = &.{},
    /// The watched directory, or the directory of the watched file.
    directory: []u8 = &.{},
    file: ?[]u8 = null,
    prefix: []u8 = &.{},
    recursive: bool = false,
    debounce_ms: u32 = 50,
    ignore: ?Ignore = null,
    // Under the plugin mutex.
    phase: enum { free, running, finished } = .free,
    stop: bool = false,
    ready: bool = false,
    batch: ?scan.Batch = null,
    changed: bool = false,
    watcher: ?*system_watch.Watcher = null,
    result: ?Service.Code = null,
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    options: Options,
    main_thread: std.Thread.Id,
    roots: []Owned = &.{},
    dispatcher: Dispatcher = .init(unset),
    implementation: Implementation = .{},
    host: ?*runtime.Host = null,
    watches: [limits.max_pending]Watch = @splat(.{}),
    mutex: zio.Mutex = .{},
    taken: zio.Condition = .{},
    outbox: runtime.Outbox,

    /// Main thread. Checks and copies the roots; returns `InvalidRoot` for a
    /// bad name or a path that is not absolute, a directory or a file.
    /// `allocator` must be thread-safe: workers allocate with it.
    pub fn init(self: *Plugin, allocator: std.mem.Allocator, options: Options) !void {
        self.* = .{ .allocator = allocator, .options = options, .main_thread = std.Thread.getCurrentId(), .outbox = .{ .post = options.post, .drain = .{ .context = self, .call = drain } } };
        const roots = try allocator.alloc(Owned, options.roots.len);
        var done: usize = 0;
        errdefer {
            for (roots[0..done]) |root| freeRoot(allocator, root);
            allocator.free(roots);
        }
        for (options.roots, 0..) |root, index| {
            for (options.roots[0..index]) |other| if (std.mem.eql(u8, other.name, root.name)) return error.InvalidRoot;
            roots[index] = try own(allocator, root);
            done += 1;
        }
        self.roots = roots;
    }

    /// Main thread, after `App.run` returned and with the Host detached:
    /// stops the watches and joins their workers.
    pub fn deinit(self: *Plugin) void {
        self.outbox.stop();
        for (&self.watches) |*watch| self.halt(watch);
        for (&self.watches) |*watch| {
            if (watch.thread) |thread| thread.join();
            watch.thread = null;
            if (watch.live) watch.work.deinit();
            watch.live = false;
            if (watch.phase != .free) self.release(watch);
        }
        for (self.roots) |root| freeRoot(self.allocator, root);
        self.allocator.free(self.roots);
        self.* = undefined;
    }

    pub fn plugin(self: *Plugin) runtime.Plugin {
        return .{ .name = Service.name, .endpoint = .{ .context = self, .vtable = &vtable } };
    }

    const vtable: runtime.Endpoint.VTable = .{ .open = open, .receive = receive, .close = close };

    fn open(context: *anyopaque, host: *runtime.Host, session: ipc.Session) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.reset(session, &canceled) catch {};
        self.abandonAll();
        self.host = host;
    }

    fn close(context: *anyopaque, _: *runtime.Host) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.close(&canceled) catch unreachable;
        self.abandonAll();
        self.host = null;
    }

    fn receive(context: *anyopaque, host: *runtime.Host, bytes: []const u8) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var action = self.dispatcher.dispatch(self.allocator, &self.implementation, self, bytes) catch return;
        switch (action) {
            .reply => |*pending| {
                defer pending.deinit();
                const packet = pending.encode(&self.dispatcher.router, self.allocator) catch return;
                _ = self.send(packet);
            },
            .taken => {},
            .cancel => |token| if (self.find(token)) |watch| self.abandon(watch),
            .ack => |ack| if (self.find(ack.token)) |watch| {
                watch.acked = @max(watch.acked, ack.sequence);
                self.deliver(watch);
            },
            .rejected => |rejected| {
                const packet = ipc.protocol.reject(self.allocator, rejected.token, rejected.code, limits.max_message_bytes) catch return;
                defer self.allocator.free(packet);
                host.send(packet) catch {};
            },
        }
    }

    fn find(self: *Plugin, token: ipc.Token) ?*Watch {
        for (&self.watches) |*watch| if (watch.live and watch.work.token.slot == token.slot and watch.work.token.id == token.id) return watch;
        return null;
    }

    fn abandonAll(self: *Plugin) void {
        for (&self.watches) |*watch| if (watch.live) self.abandon(watch);
    }

    /// The page no longer waits: stop the worker and forget the call. The
    /// watch is released once its worker has ended.
    fn abandon(self: *Plugin, watch: *Watch) void {
        watch.live = false;
        watch.work.deinit();
        self.halt(watch);
        self.reap(watch);
    }

    fn halt(self: *Plugin, watch: *Watch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        watch.stop = true;
        if (watch.watcher) |watcher| watcher.interrupt();
        self.taken.broadcast();
    }

    fn reap(self: *Plugin, watch: *Watch) void {
        self.mutex.lock();
        const finished = watch.phase == .finished;
        self.mutex.unlock();
        if (!finished) return;
        // The worker has nothing left to do but return.
        if (watch.thread) |thread| thread.join();
        watch.thread = null;
        self.release(watch);
    }

    fn release(self: *Plugin, watch: *Watch) void {
        std.debug.assert(!watch.live);
        if (watch.batch) |*batch| batch.deinit();
        self.allocator.free(watch.target);
        self.allocator.free(watch.directory);
        if (watch.file) |file| self.allocator.free(file);
        self.allocator.free(watch.prefix);
        if (watch.quota) if (self.options.quota) |quota| quota.give();
        watch.* = .{};
    }

    fn send(self: *Plugin, packet: []u8) bool {
        defer self.allocator.free(packet);
        const host = self.host orelse return false;
        // A failed send closes this endpoint before it returns.
        host.send(packet) catch return false;
        return true;
    }

    fn fail(self: *Plugin, token: ipc.Token, code: Service.Code) void {
        const packet = self.dispatcher.router.fail("watch", self.allocator, token, code, message(code)) catch return;
        _ = self.send(packet);
    }

    /// Main thread: checks the request and starts its worker.
    fn start(self: *Plugin, work: Work) void {
        var owned = work;
        const token = owned.token;
        const failure = self.prepare(&owned) orelse return;
        owned.deinit();
        self.fail(token, failure);
    }

    /// Starts the watch, or returns why not.
    fn prepare(self: *Plugin, work: *Work) ?Service.Code {
        const params = work.params;
        const watch = for (&self.watches) |*watch| {
            if (watch.phase == .free) break watch;
        } else return .limit;
        if (!validName(params.root) or !validPath(params.path)) return .denied;
        if (params.debounceMs > 60000) return .limit;
        var resolved: ?Owned = null;
        defer if (resolved) |root| freeRoot(self.allocator, root);
        const root: Owned = for (self.roots) |root| {
            if (std.mem.eql(u8, root.name, params.root)) break root;
        } else lookup: {
            const resolve = self.options.resolve orelse return .denied;
            const found = resolve.resolve(resolve.context, params.root) orelse return .denied;
            resolved = own(self.allocator, found) catch |err| return switch (err) {
                error.OutOfMemory => .io,
                else => .denied,
            };
            break :lookup resolved.?;
        };
        const target = locate(root, params.path) catch |err| return switch (err) {
            error.FileNotFound => .@"not-found",
            error.Denied => .denied,
            error.Replaced => .io,
            else => .io,
        };
        // A root that is not recursive lets pages watch itself and the files
        // in it, not the directories.
        if (params.recursive and !root.recursive) return .denied;
        if (!root.recursive and !std.mem.eql(u8, params.path, ".") and (target.directory or std.mem.indexOfScalar(u8, params.path, '/') != null)) return .denied;
        if (self.options.allow) |allow| if (!allow.allow(allow.context, .{ .root = params.root, .path = params.path, .recursive = params.recursive })) return .denied;
        if (self.options.quota) |quota| if (!quota.take()) return .limit;
        watch.quota = self.options.quota != null;
        self.fill(watch, root, params, target) catch {
            self.release(watch);
            return .io;
        };
        watch.phase = .running;
        watch.thread = std.Thread.spawn(.{}, worker, .{ self, watch }) catch {
            watch.phase = .free;
            self.release(watch);
            return .io;
        };
        watch.work = work.*;
        work.storage = null;
        watch.live = true;
        return null;
    }

    fn fill(self: *Plugin, watch: *Watch, root: Owned, params: Service.Request, target: Target) !void {
        watch.prefix = try self.allocator.dupe(u8, params.path);
        watch.target = if (std.mem.eql(u8, params.path, ".")) try self.allocator.dupe(u8, root.path) else joined: {
            const path = try std.fmt.allocPrint(self.allocator, "{s}{c}{s}", .{ root.path, separator, params.path });
            if (is_windows) std.mem.replaceScalar(u8, path, '/', '\\');
            break :joined path;
        };
        if (target.directory) {
            watch.directory = try self.allocator.dupe(u8, watch.target);
        } else {
            const parent = std.fs.path.dirname(watch.target) orelse return error.Denied;
            watch.directory = try self.allocator.dupe(u8, parent);
            watch.file = try self.allocator.dupe(u8, std.fs.path.basename(watch.target));
        }
        watch.recursive = params.recursive;
        watch.debounce_ms = if (params.debounceMs == 0) 50 else if (params.debounceMs < 0) 0 else @intCast(params.debounceMs);
        watch.ignore = root.ignore;
    }

    /// Main thread, in the posted drain: hands what workers produced to the
    /// page.
    fn drain(context: *anyopaque) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        self.outbox.begin();
        var touched: [limits.max_pending]*Watch = undefined;
        var count: usize = 0;
        self.mutex.lock();
        for (&self.watches) |*watch| if (watch.changed) {
            watch.changed = false;
            touched[count] = watch;
            count += 1;
        };
        self.mutex.unlock();
        for (touched[0..count]) |watch| {
            if (watch.live) self.deliver(watch) else self.reap(watch);
        }
    }

    /// Main thread: sends ready, then the parts of the batch while the page
    /// has credit, then the result once the worker has ended.
    fn deliver(self: *Plugin, watch: *Watch) void {
        const token = watch.work.token;
        self.mutex.lock();
        const ready = watch.ready;
        self.mutex.unlock();
        if (ready and !watch.ready_sent) {
            const packet = self.dispatcher.router.chunk("watch", self.allocator, token, .{ .ready = true, .events = &.{}, .more = false }) catch |err| switch (err) {
                error.Backpressure => return,
                else => return self.end(watch, .io),
            };
            watch.ready_sent = true;
            watch.chunks += 1;
            if (!self.send(packet)) return;
        }
        while (watch.live) {
            self.mutex.lock();
            const events = if (watch.batch) |batch| batch.events else null;
            self.mutex.unlock();
            const all = events orelse break;
            const start_at = watch.parts_sent;
            var end_at = start_at;
            var bytes: usize = 0;
            while (end_at < all.len) : (end_at += 1) {
                const event = all[end_at];
                // JSON escapes a byte in at most six.
                const size = 64 + 6 * (event.path.len + if (event.oldPath) |old| old.len else 0);
                if (end_at > start_at and bytes + size > part_bytes) break;
                bytes += size;
            }
            const more = end_at < all.len;
            const packet = self.dispatcher.router.chunk("watch", self.allocator, token, .{ .ready = false, .events = all[start_at..end_at], .more = more }) catch |err| switch (err) {
                error.Backpressure => return,
                else => return self.end(watch, .io),
            };
            if (more) {
                watch.parts_sent = end_at;
            } else {
                watch.parts_sent = 0;
                self.mutex.lock();
                watch.batch.?.deinit();
                watch.batch = null;
                self.taken.broadcast();
                self.mutex.unlock();
            }
            watch.chunks += 1;
            if (!self.send(packet)) return;
        }
        if (!watch.live) return;
        self.mutex.lock();
        const finished = watch.phase == .finished and watch.batch == null;
        const result = watch.result;
        self.mutex.unlock();
        if (!finished or (result != null and watch.acked < watch.chunks)) return;
        watch.live = false;
        watch.work.deinit();
        if (result) |code| self.fail(token, code) else if (self.dispatcher.router.complete("watch", self.allocator, token, {})) |packet| {
            _ = self.send(packet);
        } else |_| {}
        self.reap(watch);
    }

    /// Main thread: the page can no longer be told of the watch; it fails
    /// with `code` and stops.
    fn end(self: *Plugin, watch: *Watch, code: Service.Code) void {
        const token = watch.work.token;
        watch.live = false;
        watch.work.deinit();
        self.halt(watch);
        self.fail(token, code);
        self.reap(watch);
    }

    /// Worker: marks the watch changed for the next drain.
    fn changed(self: *Plugin, watch: *Watch) void {
        watch.changed = true;
        self.mutex.unlock();
        self.outbox.notify();
    }
};

fn worker(self: *Plugin, watch: *Watch) void {
    const result = run(self, watch);
    self.mutex.lock();
    watch.phase = .finished;
    watch.result = result;
    self.changed(watch);
}

/// Worker: the watch from start to end; the code of what stopped it, or
/// null when it ended because what it watched went away or was stopped.
fn run(self: *Plugin, watch: *Watch) ?Service.Code {
    if (!system_watch.capabilities.coarse) return .unsupported;
    const latency: u32 = @max(500, watch.debounce_ms);
    var watcher = system_watch.Watcher.init(self.allocator, self.main_thread, .{
        .recursive = watch.recursive,
        .debounce_ms = watch.debounce_ms,
        .max_latency_ms = latency,
        .max_roots = 1,
        .max_directories = if (watch.recursive) self.options.max_directories else 1,
    }) catch return .io;
    defer watcher.deinit();
    self.mutex.lock();
    if (watch.stop) {
        self.mutex.unlock();
        return null;
    }
    watch.watcher = &watcher;
    self.mutex.unlock();
    defer {
        self.mutex.lock();
        watch.watcher = null;
        self.mutex.unlock();
    }
    _ = watcher.addRoot(watch.directory) catch |err| return addFailure(err);
    var dir = std.Io.Dir.openDirAbsolute(zio.io(), watch.directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => .@"not-found",
        else => .io,
    };
    defer dir.close(zio.io());
    var state: scan.Scan = .{
        .allocator = self.allocator,
        .dir = dir,
        .path = watch.directory,
        .file = watch.file,
        .recursive = watch.recursive,
        .max_entries = self.options.max_entries,
        .ignore = watch.ignore,
        .prefix = watch.prefix,
    };
    defer state.deinit();
    state.start() catch |err| return codeOf(err);

    self.mutex.lock();
    watch.ready = true;
    self.changed(watch);

    var events: [64]system_watch.Event = undefined;
    const paths = self.allocator.alloc(u8, @max(64 * 1024, system_watch.max_path_bytes + 1)) catch return .io;
    defer self.allocator.free(paths);
    while (true) {
        // Nothing is looked at again until the page has the last batch.
        self.mutex.lock();
        while (watch.batch != null and !watch.stop) self.taken.wait(&self.mutex);
        const stop = watch.stop;
        self.mutex.unlock();
        if (stop) return null;
        var gone = false;
        var timeout: ?u32 = null;
        while (true) {
            const batch = watcher.wait(&events, paths, timeout) catch |err| return switch (err) {
                error.ResultCapacityExceeded => .@"path-encoding",
                else => .io,
            };
            for (batch.events) |event| switch (event) {
                .changed => |change| state.changed(watch.directory, change.path) catch |err| switch (err) {
                    error.Gone => gone = true,
                    else => return codeOf(err),
                },
                .overflow => state.rescan() catch |err| switch (err) {
                    error.Gone => gone = true,
                    else => return codeOf(err),
                },
                .root_removed => gone = true,
            };
            if (gone or !batch.more) break;
            timeout = 0;
        }
        // The last batch only says what is watched went away.
        var result = (if (gone) state.gone() else state.events()) catch |err| return codeOf(err);
        if (result.events.len == 0) {
            result.deinit();
            if (gone) return null;
            continue;
        }
        self.mutex.lock();
        if (watch.stop) {
            self.mutex.unlock();
            result.deinit();
            return null;
        }
        watch.batch = result;
        self.changed(watch);
        if (gone) return null;
    }
}

/// The platforms' watchers fail in different sets of errors.
fn addFailure(err: anyerror) Service.Code {
    return switch (err) {
        error.FileNotFound => .@"not-found",
        error.DirectoryBudgetExceeded, error.WatchLimitReached => .limit,
        else => .io,
    };
}

fn codeOf(err: scan.Error) Service.Code {
    return switch (err) {
        error.Limit => .limit,
        error.PathEncoding => .@"path-encoding",
        error.Gone => .@"not-found",
        error.OutOfMemory, error.Io => .io,
    };
}

fn message(value: Service.Code) []const u8 {
    return switch (value) {
        .denied => "filesystem watch denied",
        .limit => "filesystem watch limit",
        .@"not-found" => "filesystem watch not found",
        .unsupported => "filesystem watch unsupported",
        .@"path-encoding" => "filesystem watch path encoding",
        .io => "filesystem watch io",
    };
}

const Implementation = struct {
    pub fn watch(_: *Implementation, plugin: *Plugin, work: Work) void {
        plugin.start(work);
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isLower(name[0])) return false;
    for (name) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    return true;
}

/// A path relative to a root, separated by slashes, that stays in it.
fn validPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, ".")) return true;
    if (path.len == 0 or path.len > 4095) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| if (byte == 0 or byte == '\\' or (is_windows and (byte == ':' or byte < 32))) return false;
    }
    return true;
}

fn own(allocator: std.mem.Allocator, root: Root) !Owned {
    if (!validName(root.name) or !std.fs.path.isAbsolute(root.path)) return error.InvalidRoot;
    const resolved = zio.realPathAlloc(std.Io.Dir.cwd(), root.path, allocator) catch return error.InvalidRoot;
    errdefer allocator.free(resolved);
    const entry = scan.lstatAbsolute(resolved) catch return error.InvalidRoot;
    if (entry.id.kind != .directory and entry.id.kind != .file) return error.InvalidRoot;
    const name = try allocator.dupe(u8, root.name);
    return .{ .name = name, .path = resolved, .recursive = root.recursive, .ignore = root.ignore, .identity = if (entry.isDir()) entry.id else null };
}

fn freeRoot(allocator: std.mem.Allocator, root: Owned) void {
    allocator.free(root.name);
    allocator.free(root.path);
}

const Target = struct { directory: bool };

/// What `path` names in `root`, through its directories without following
/// a symlink.
fn locate(root: Owned, path: []const u8) !Target {
    const entry = scan.lstatAbsolute(root.path) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        else => error.Io,
    };
    if (root.identity) |identity| if (!std.meta.eql(identity, entry.id)) return error.Replaced;
    if (root.identity == null and entry.id.kind != .file) return error.Replaced;
    if (std.mem.eql(u8, path, ".")) return .{ .directory = entry.isDir() };
    if (!entry.isDir()) return error.Denied;
    var dir = try std.Io.Dir.openDirAbsolute(zio.io(), root.path, .{ .follow_symlinks = false });
    defer dir.close(zio.io());
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        const found = scan.statAt(dir, part) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Io,
        };
        const last = parts.peek() == null;
        if (last) {
            if (found.id.kind != .directory and found.id.kind != .file) return error.Denied;
            return .{ .directory = found.isDir() };
        }
        if (found.id.kind != .directory) return error.Denied;
        const next = try dir.openDir(zio.io(), part, .{ .follow_symlinks = false });
        dir.close(zio.io());
        dir = next;
    }
    unreachable;
}

test {
    _ = scan;
    _ = @import("watch_test.zig");
}
