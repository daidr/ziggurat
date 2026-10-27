//! The process-wide `std.Io` Ziggurat uses for files, processes, networking,
//! clocks, entropy and blocking synchronization.
//!
//! By default this is a `std.Io.Threaded` created on first use, carrying the
//! environment and argv[0] the start code captured. An application that owns
//! its own `Io` (for example the one `std.process.Init` hands to `main`) may
//! install it with `set` before any Ziggurat call; afterwards it is fixed for
//! the life of the process.
//!
//! The synchronization types keep the shape of the blocking, uncancelable
//! primitives Ziggurat's threads are written against: native and UI work never
//! observes `error.Canceled`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const posix = @import("posix.zig");
pub const net = @import("net.zig");

var threaded: Io.Threaded = undefined;
var installed: Io = undefined;
var state: std.atomic.Value(u8) = .init(unset);
const unset = 0;
const initializing = 1;
const ready = 2;

/// The process-wide `Io`.
pub fn io() Io {
    if (state.load(.acquire) != ready) initialize();
    return installed;
}

/// Installs `value` as the process-wide `Io`. Returns `error.AlreadyInitialized`
/// once `io` has been used or `set` has already succeeded.
pub fn set(value: Io) error{AlreadyInitialized}!void {
    if (state.cmpxchgStrong(unset, initializing, .acquire, .acquire) != null) return error.AlreadyInitialized;
    installed = value;
    state.store(ready, .release);
}

fn initialize() void {
    @branchHint(.cold);
    if (state.cmpxchgStrong(unset, initializing, .acquire, .acquire)) |observed| {
        if (observed == ready) return;
        while (state.load(.acquire) != ready) std.Thread.yield() catch {};
        return;
    }
    const startup = Io.Threaded.global_single_threaded;
    threaded = .init(std.heap.smp_allocator, .{
        .argv0 = startup.argv0,
        .environ = startup.environ.process_environ,
    });
    installed = threaded.io();
    state.store(ready, .release);
}

pub const Mutex = struct {
    inner: Io.Mutex = .init,

    pub fn lock(m: *Mutex) void {
        m.inner.lockUncancelable(io());
    }
    pub fn tryLock(m: *Mutex) bool {
        return m.inner.tryLock();
    }
    pub fn unlock(m: *Mutex) void {
        m.inner.unlock(io());
    }
};

pub const Condition = struct {
    inner: Io.Condition = .init,

    pub fn wait(c: *Condition, mutex: *Mutex) void {
        c.inner.waitUncancelable(io(), &mutex.inner);
    }
    /// Waits at most `timeout_ns`. Spurious wakeups are possible, as with
    /// `wait`.
    pub fn timedWait(c: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const value = io();
        const protection = value.swapCancelProtection(.blocked);
        defer _ = value.swapCancelProtection(protection);
        c.inner.waitTimeout(value, &mutex.inner, duration(timeout_ns)) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => unreachable,
        };
    }
    pub fn signal(c: *Condition) void {
        c.inner.signal(io());
    }
    pub fn broadcast(c: *Condition) void {
        c.inner.broadcast(io());
    }
};

pub const ResetEvent = struct {
    inner: Io.Event = .unset,

    pub fn isSet(e: *const ResetEvent) bool {
        return e.inner.isSet();
    }
    pub fn set(e: *ResetEvent) void {
        e.inner.set(io());
    }
    pub fn reset(e: *ResetEvent) void {
        e.inner.reset();
    }
    pub fn wait(e: *ResetEvent) void {
        e.inner.waitUncancelable(io());
    }
    pub fn timedWait(e: *ResetEvent, timeout_ns: u64) error{Timeout}!void {
        const value = io();
        const protection = value.swapCancelProtection(.blocked);
        defer _ = value.swapCancelProtection(protection);
        e.inner.waitTimeout(value, duration(timeout_ns)) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => unreachable,
        };
    }
};

pub const Semaphore = struct {
    inner: Io.Semaphore = .{},

    pub fn init(permits: usize) Semaphore {
        return .{ .inner = .{ .permits = permits } };
    }
    pub fn wait(s: *Semaphore) void {
        s.inner.waitUncancelable(io());
    }
    pub fn timedWait(s: *Semaphore, timeout_ns: u64) error{Timeout}!void {
        const value = io();
        const protection = value.swapCancelProtection(.blocked);
        defer _ = value.swapCancelProtection(protection);
        s.inner.waitTimeout(value, duration(timeout_ns)) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => unreachable,
        };
    }
    pub fn post(s: *Semaphore) void {
        s.inner.post(io());
    }
};

/// Counts started work down to zero; `wait` blocks until it gets there.
pub const WaitGroup = struct {
    pending: std.atomic.Value(usize) = .init(0),
    done: ResetEvent = .{},

    pub fn start(g: *WaitGroup) void {
        if (g.pending.fetchAdd(1, .acq_rel) == 0) g.done.reset();
    }
    pub fn finish(g: *WaitGroup) void {
        if (g.pending.fetchSub(1, .acq_rel) == 1) g.done.set();
    }
    pub fn wait(g: *WaitGroup) void {
        if (g.pending.load(.acquire) == 0) return;
        g.done.wait();
    }
};

/// Address-based waiting on a 32-bit atomic word.
pub const Futex = struct {
    pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32) void {
        io().futexWaitUncancelable(u32, &ptr.raw, expect);
    }
    pub fn timedWait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ns: u64) error{Timeout}!void {
        const value = io();
        const protection = value.swapCancelProtection(.blocked);
        defer _ = value.swapCancelProtection(protection);
        const deadline: Io.Clock.Timestamp = .fromNow(value, .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake });
        value.futexWaitTimeout(u32, &ptr.raw, expect, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        if (ptr.load(.acquire) == expect and deadline.durationFromNow(value).raw.nanoseconds <= 0) return error.Timeout;
    }
    pub fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        io().futexWake(u32, &ptr.raw, max_waiters);
    }
};

fn duration(timeout_ns: u64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } };
}

/// Blocks the calling thread for at least `ns` nanoseconds.
pub fn sleep(ns: u64) void {
    const value = io();
    const protection = value.swapCancelProtection(.blocked);
    defer _ = value.swapCancelProtection(protection);
    value.sleep(.fromNanoseconds(ns), .awake) catch |err| switch (err) {
        error.Canceled => unreachable,
    };
}

/// Wall-clock time since the Unix epoch.
pub fn nanoTimestamp() i128 {
    return Io.Clock.real.now(io()).nanoseconds;
}
pub fn microTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_us));
}
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}
pub fn timestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_s));
}

/// A reading of the monotonic clock, which keeps counting while the system
/// is suspended.
pub const Instant = struct {
    timestamp: i96,

    pub fn now() error{Unsupported}!Instant {
        return .{ .timestamp = Io.Clock.boot.now(io()).nanoseconds };
    }
    pub fn order(self: Instant, other: Instant) std.math.Order {
        return std.math.order(self.timestamp, other.timestamp);
    }
    /// Nanoseconds from `earlier` to `self`, saturating at zero.
    pub fn since(self: Instant, earlier: Instant) u64 {
        if (self.timestamp <= earlier.timestamp) return 0;
        return std.math.cast(u64, self.timestamp - earlier.timestamp) orelse std.math.maxInt(u64);
    }
};

/// Elapsed monotonic time.
pub const Timer = struct {
    started: Instant,
    previous: Instant,

    pub const Error = error{TimerUnsupported};

    pub fn start() Error!Timer {
        const current = Instant.now() catch return error.TimerUnsupported;
        return .{ .started = current, .previous = current };
    }
    pub fn read(self: *Timer) u64 {
        const current = self.sample();
        return current.since(self.started);
    }
    pub fn reset(self: *Timer) void {
        const current = self.sample();
        self.started = current;
    }
    pub fn lap(self: *Timer) u64 {
        const current = self.sample();
        defer self.started = current;
        return current.since(self.started);
    }
    fn sample(self: *Timer) Instant {
        const current = Instant.now() catch unreachable;
        if (current.order(self.previous) == .gt) self.previous = current;
        return self.previous;
    }
};

var random_context: u8 = 0;

/// Cryptographically strong random numbers from the process-wide `Io`.
pub const random: std.Random = .{ .ptr = &random_context, .fillFn = fillRandom };

fn fillRandom(_: *anyopaque, buffer: []u8) void {
    io().random(buffer);
}

pub const EnvVarError = error{ EnvironmentVariableNotFound, InvalidWtf8, OutOfMemory };

/// The value of an environment variable, owned by the caller. Reads the live
/// environment, so changes made with `setenv` after startup are visible.
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) EnvVarError![]u8 {
    if (builtin.os.tag == .windows) {
        return environ().getAlloc(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => error.EnvironmentVariableNotFound,
            error.InvalidWtf8 => error.InvalidWtf8,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
    const value = getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}

/// Whether an environment variable is set.
pub fn hasEnvVar(allocator: std.mem.Allocator, key: []const u8) error{ InvalidWtf8, OutOfMemory }!bool {
    if (builtin.os.tag == .windows) return environ().contains(allocator, key) catch |err| switch (err) {
        error.Unexpected => unreachable,
        else => |e| e,
    };
    return getenv(key) != null;
}

/// The value of an environment variable on POSIX systems, borrowed from the
/// environment. Reads the live environment when linking libc.
pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (builtin.os.tag == .windows) @compileError("getenv is not available on Windows; use getEnvVarOwned");
    if (builtin.link_libc) {
        var buffer: [256]u8 = undefined;
        if (key.len >= buffer.len or std.mem.indexOfScalar(u8, key, 0) != null) return scan(std.mem.span(std.c.environ), key);
        @memcpy(buffer[0..key.len], key);
        buffer[key.len] = 0;
        const found = std.c.getenv(buffer[0..key.len :0]) orelse return null;
        return std.mem.span(found);
    }
    return environ().getPosix(key);
}

fn scan(block: []const ?[*:0]u8, key: []const u8) ?[:0]const u8 {
    for (block) |entry_ptr| {
        const entry = std.mem.span(entry_ptr orelse continue);
        if (entry.len > key.len and entry[key.len] == '=' and std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

/// A copy of the environment, owned by the caller.
pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (builtin.os.tag != .windows and builtin.link_libc) {
        var map: std.process.Environ.Map = .init(allocator);
        errdefer map.deinit();
        try map.putPosixBlock(.{ .slice = @ptrCast(std.mem.span(std.c.environ)) });
        return map;
    }
    return environ().createMap(allocator);
}

/// The environment the process started with.
pub fn environ() std.process.Environ {
    return Io.Threaded.global_single_threaded.environ.process_environ;
}

/// Starts a child process. When the options name no environment the child
/// inherits the live environment of this process.
pub fn spawn(options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    var copy = options;
    var map: ?std.process.Environ.Map = null;
    defer if (map) |*value| value.deinit();
    if (options.environ_map == null and builtin.os.tag != .windows and builtin.link_libc) {
        map = getEnvMap(std.heap.smp_allocator) catch return error.SystemResources;
        copy.environ_map = &map.?;
    }
    return std.process.spawn(io(), copy);
}

/// Forcibly ends a child and waits for it, returning how it ended; a child
/// that already exited reports its own status.
pub fn terminate(child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(child.id.?, @fromBackingInt(1));
    } else {
        std.posix.kill(child.id.?, .KILL) catch {};
    }
    return child.wait(io());
}

/// The per-user directory for `name`'s data: `%APPDATA%\\name` on Windows,
/// `~/Library/Application Support/name` on macOS and
/// `$XDG_DATA_HOME/name` (default `~/.local/share/name`) elsewhere.
pub fn appDataDir(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = try getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, name });
    }
    if (builtin.os.tag.isDarwin()) {
        const home = getenv("HOME") orelse return error.AppDataDirUnavailable;
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", name });
    }
    if (getenv("XDG_DATA_HOME")) |base| if (base.len != 0) return std.fs.path.join(allocator, &.{ base, name });
    const home = getenv("HOME") orelse return error.AppDataDirUnavailable;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", name });
}

/// The resolved absolute path of `sub_path` in `dir`, owned by the caller
/// as a plain slice (std returns a sentinel slice that must be freed as one).
pub fn realPathAlloc(dir: std.Io.Dir, sub_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const terminated = try dir.realPathFileAlloc(io(), sub_path, allocator);
    defer allocator.free(terminated);
    return allocator.dupe(u8, terminated);
}

/// This executable's path, owned by the caller as a plain slice.
pub fn executablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const terminated = try std.process.executablePathAlloc(io(), allocator);
    defer allocator.free(terminated);
    return allocator.dupe(u8, terminated);
}

/// A child's working directory: `path`, or this process's when null.
pub fn cwd(path: ?[]const u8) std.process.Child.Cwd {
    return if (path) |value| .{ .path = value } else .inherit;
}

/// Replaces this process with another program; returns only on failure.
/// When the options name no environment the program gets the live one.
pub fn replace(options: std.process.ReplaceOptions) std.process.ReplaceError {
    var copy = options;
    var map: ?std.process.Environ.Map = null;
    defer if (map) |*value| value.deinit();
    if (options.environ_map == null and builtin.os.tag != .windows and builtin.link_libc) {
        map = getEnvMap(std.heap.smp_allocator) catch return error.SystemResources;
        copy.environ_map = &map.?;
    }
    return std.process.replace(io(), copy);
}

/// Runs a child process to completion, collecting its output. When the
/// options name no environment the child inherits the live environment.
pub fn run(allocator: std.mem.Allocator, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    var copy = options;
    var map: ?std.process.Environ.Map = null;
    defer if (map) |*value| value.deinit();
    if (options.environ_map == null and builtin.os.tag != .windows and builtin.link_libc) {
        map = getEnvMap(std.heap.smp_allocator) catch return error.SystemResources;
        copy.environ_map = &map.?;
    }
    return std.process.run(allocator, io(), copy);
}

/// The command line arguments `main` received, copied into one allocation the
/// caller frees with `argsFree`.
pub fn argsAlloc(allocator: std.mem.Allocator, args: std.process.Args) ![][:0]u8 {
    var it = try args.iterateAllocator(allocator);
    defer it.deinit();
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    var lengths: std.ArrayList(usize) = .empty;
    defer lengths.deinit(allocator);
    while (it.next()) |arg| {
        try contents.appendSlice(allocator, arg[0 .. arg.len + 1]);
        try lengths.append(allocator, arg.len);
    }
    const list_bytes = try std.math.mul(usize, @sizeOf([:0]u8), lengths.items.len);
    const buffer = try allocator.alignedAlloc(u8, .of([:0]u8), try std.math.add(usize, list_bytes, contents.items.len));
    const result = std.mem.bytesAsSlice([:0]u8, buffer[0..list_bytes]);
    const bytes = buffer[list_bytes..];
    @memcpy(bytes, contents.items);
    var offset: usize = 0;
    for (lengths.items, 0..) |len, index| {
        result[index] = bytes[offset..][0..len :0];
        offset += len + 1;
    }
    return result;
}

/// Frees the result of `argsAlloc`.
pub fn argsFree(allocator: std.mem.Allocator, args: []const [:0]u8) void {
    var total: usize = @sizeOf([:0]u8) * args.len;
    for (args) |arg| total += arg.len + 1;
    const start: [*]align(@alignOf([:0]u8)) const u8 = @ptrCast(args.ptr);
    allocator.free(start[0..total]);
}

/// A file written beside its destination and moved into place in one step, so
/// readers see either the old contents or the new ones.
pub const AtomicFile = struct {
    atomic: std.Io.File.Atomic,
    file_writer: std.Io.File.Writer,

    pub const Options = struct {
        permissions: std.Io.File.Permissions = .default_file,
        make_path: bool = false,
        write_buffer: []u8,
    };

    pub fn init(dir: std.Io.Dir, sub_path: []const u8, options: Options) std.Io.Dir.CreateFileAtomicError!AtomicFile {
        const atomic = try dir.createFileAtomic(io(), sub_path, .{ .permissions = options.permissions, .make_path = options.make_path, .replace = true });
        return .{ .atomic = atomic, .file_writer = atomic.file.writer(io(), options.write_buffer) };
    }

    /// Removes the temporary file unless it was moved into place.
    pub fn deinit(self: *AtomicFile) void {
        self.atomic.deinit(io());
    }

    pub fn flush(self: *AtomicFile) std.Io.File.Writer.Error!void {
        self.file_writer.interface.flush() catch return self.file_writer.err.?;
    }

    /// Replaces the destination with the written file.
    pub fn renameIntoPlace(self: *AtomicFile) std.Io.File.Atomic.ReplaceError!void {
        try self.atomic.replace(io());
    }

    /// Flushes and moves the file into place.
    pub fn finish(self: *AtomicFile) !void {
        try self.flush();
        try self.renameIntoPlace();
    }
};

/// Reads from the file's current position until `buffer` is full or the file
/// ends, returning how many bytes were read.
/// One read of at most `buffer.len` bytes; 0 at end of file.
pub fn read(file: std.Io.File, buffer: []u8) std.Io.File.Reader.Error!usize {
    return file.readStreaming(io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| e,
    };
}

pub fn readAll(file: std.Io.File, buffer: []u8) std.Io.File.Reader.Error!usize {
    var count: usize = 0;
    while (count < buffer.len) {
        const n = file.readStreaming(io(), &.{buffer[count..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        count += n;
    }
    return count;
}

/// The rest of the file from its current position, owned by the caller.
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var reader = file.readerStreaming(io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.FileTooBig,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// The path of the running executable, in `buffer`.
pub fn selfExePath(buffer: []u8) std.process.ExecutablePathError![]u8 {
    return buffer[0..try std.process.executablePath(io(), buffer)];
}

/// The current working directory, in `buffer`.
pub fn getCwd(buffer: []u8) std.process.CurrentPathError![]u8 {
    return buffer[0..try std.process.currentPath(io(), buffer)];
}

/// The canonical absolute path of `sub_path` relative to `dir`, in `buffer`.
pub fn realpath(dir: std.Io.Dir, sub_path: []const u8, buffer: []u8) std.Io.Dir.RealPathFileError![]u8 {
    return buffer[0..try dir.realPathFile(io(), sub_path, buffer)];
}

/// File permissions from a POSIX mode; systems without modes use the default.
pub fn mode(value: u32) std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(@intCast(value)) else .default_file;
}

/// The POSIX mode bits of `permissions`; 0 on systems without modes.
pub fn modeOf(permissions: std.Io.File.Permissions) u32 {
    return if (@hasDecl(std.Io.File.Permissions, "toMode")) @intCast(permissions.toMode()) else 0;
}

/// One row of a struct, enum or union's fields, in declaration order. `type`
/// is `void` for enums and `value` is zero for structs and unions.
pub const Field = struct {
    name: [:0]const u8,
    type: type,
    value: comptime_int = 0,
    is_comptime: bool = false,
    default_value_ptr: ?*const anyopaque = null,
};

/// The fields of a struct, enum or union as rows, for `inline for` loops that
/// read names and types together.
pub inline fn fields(comptime T: type) []const Field {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => |info| rows(info.field_names, info.field_types, null, info.field_attrs),
            .@"union" => |info| rows(info.field_names, info.field_types, null, null),
            .@"enum" => |info| rows(info.field_names, null, info.field_values, null),
            else => @compileError("fields expects a struct, enum or union, found " ++ @typeName(T)),
        };
    }
}

fn rows(
    comptime names: []const [:0]const u8,
    comptime types: ?[]const type,
    comptime values: ?[]const comptime_int,
    comptime attrs: ?[]const std.builtin.Type.Struct.FieldAttributes,
) []const Field {
    var result: [names.len]Field = undefined;
    for (names, 0..) |name, index| result[index] = .{
        .name = name,
        .type = if (types) |list| list[index] else void,
        .value = if (values) |list| list[index] else 0,
        .is_comptime = if (attrs) |list| list[index].@"comptime" else false,
        .default_value_ptr = if (attrs) |list| list[index].default_value_ptr else null,
    };
    const final = result;
    return &final;
}

test "timers and clocks advance" {
    var timer = try Timer.start();
    sleep(std.time.ns_per_ms);
    try std.testing.expect(timer.read() >= std.time.ns_per_ms);
    try std.testing.expect(milliTimestamp() > 1_600_000_000_000);
}

test "synchronization primitives hand off across threads" {
    const Shared = struct {
        mutex: Mutex = .{},
        condition: Condition = .{},
        ready: bool = false,
        event: ResetEvent = .{},
        fn run(self: *@This()) void {
            self.mutex.lock();
            self.ready = true;
            self.condition.signal();
            self.mutex.unlock();
            self.event.set();
        }
    };
    var shared: Shared = .{};
    const thread = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    shared.mutex.lock();
    while (!shared.ready) shared.condition.wait(&shared.mutex);
    shared.mutex.unlock();
    shared.event.wait();
    thread.join();
    shared.mutex.lock();
    defer shared.mutex.unlock();
    while (true) shared.condition.timedWait(&shared.mutex, std.time.ns_per_ms) catch break;
    var never: ResetEvent = .{};
    try std.testing.expectError(error.Timeout, never.timedWait(std.time.ns_per_ms));
}

/// A fresh directory under `.zig-cache/tmp`, as `std.testing.tmpDir` makes
/// one, for smoke executables that are not test binaries.
pub const TmpDir = struct {
    dir: std.Io.Dir,
    parent_dir: std.Io.Dir,
    sub_path: [sub_path_len]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    pub fn cleanup(self: *TmpDir) void {
        self.dir.close(io());
        self.parent_dir.deleteTree(io(), &self.sub_path) catch {};
        self.parent_dir.close(io());
        self.* = undefined;
    }
};

pub fn tmpDir(options: std.Io.Dir.OpenOptions) TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    io().random(&random_bytes);
    var sub_path: [TmpDir.sub_path_len]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);
    var cache_dir = std.Io.Dir.cwd().createDirPathOpen(io(), ".zig-cache", .{}) catch @panic("unable to make .zig-cache");
    defer cache_dir.close(io());
    const parent_dir = cache_dir.createDirPathOpen(io(), "tmp", .{}) catch @panic("unable to make .zig-cache/tmp");
    const dir = parent_dir.createDirPathOpen(io(), &sub_path, .{ .open_options = options }) catch @panic("unable to make a temporary directory");
    return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
}

/// `std.DynLib`, which Zig 0.17 no longer provides on Windows; there the
/// library is loaded with LoadLibraryW and its symbols found by name.
pub const DynLib = if (builtin.os.tag == .windows) struct {
    module: std.os.windows.HMODULE,

    const kernel32 = struct {
        extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;
        extern "kernel32" fn GetProcAddress(std.os.windows.HMODULE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;
    };

    pub fn open(path: []const u8) error{ InvalidWtf8, NameTooLong, FileNotFound }!DynLib {
        var wide: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        if (path.len > std.os.windows.PATH_MAX_WIDE) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
        wide[len] = 0;
        return .{ .module = kernel32.LoadLibraryW(wide[0..len :0]) orelse return error.FileNotFound };
    }
    pub fn close(self: *DynLib) void {
        _ = kernel32.FreeLibrary(self.module);
        self.* = undefined;
    }
    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(@alignCast(kernel32.GetProcAddress(self.module, name.ptr) orelse return null));
    }
} else std.DynLib;

/// Runs `f` once across threads, as `std.once` did before Zig 0.17.
pub fn once(comptime f: fn () void) Once(f) {
    return .{};
}

pub fn Once(comptime f: fn () void) type {
    return struct {
        done: bool = false,
        mutex: Mutex = .{},

        pub fn call(self: *@This()) void {
            if (@atomicLoad(bool, &self.done, .acquire)) return;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.done) return;
            f();
            @atomicStore(bool, &self.done, true, .release);
        }
    };
}
