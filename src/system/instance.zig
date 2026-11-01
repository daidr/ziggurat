const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const identity = @import("identity.zig");
const z = @import("ziggurat");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

pub const max_arguments = 128;
pub const max_argument_bytes = 16 * 1024;
/// Payload bound for one forwarded message: working directory and arguments,
/// each with a four-byte length prefix.
pub const max_payload_bytes = 64 * 1024;
pub const header_bytes = 16;
/// Caller storage required by Primary.receive.
pub const receive_storage_bytes = header_bytes + max_payload_bytes;
const magic = [4]u8{ 'Z', 'G', 'I', 1 };
const ack_accepted: u8 = 'A';
const ack_rejected: u8 = 'R';

pub const capabilities = .{
    .single_instance = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos,
    .open_events = builtin.os.tag == .macos and !builtin.is_test,
};

pub const Options = struct {
    /// Application identity, see identity.validate. The OS adapter adds the
    /// current user (and on Windows the session) so other users never share it.
    id: []const u8,
    /// Bound for one connected exchange, both when sending and receiving.
    timeout_ms: u32 = 2000,
};
pub const Outgoing = struct {
    /// Absolute working directory of the second process; bytes are forwarded verbatim.
    cwd: []const u8,
    /// Usually the process arguments after argv[0]. Empty strings are kept.
    arguments: []const []const u8 = &.{},
};
pub const Message = struct {
    cwd: []const u8,
    /// Borrowed from receive storage until the next receive or deinit.
    arguments: []const []const u8,
    /// Native process ID reported by the OS for the sending peer.
    sender_process: u32,
};
pub const Rejection = enum { malformed, too_large, timeout, foreign_user, disconnected };
pub const Received = union(enum) {
    message: Message,
    /// A peer connected but its exchange was refused; the listener stays usable.
    rejected: Rejection,
    stopped,
};
pub const Claim = union(enum) { primary: Primary, secondary: Secondary };

/// What the system asks a running macOS app to open: a URL of a scheme the
/// bundle declares (a deep link) or files (Finder's Open, a drop on the
/// dock icon). macOS sends these as Apple Events, never as process
/// arguments; on Linux and Windows the same requests arrive as arguments of
/// a second process and reach the primary through claimOrForward.
pub const Open = struct {
    kind: enum { urls, files },
    /// Absolute URLs or absolute file paths, borrowed during on_open.
    items: []const []const u8,
    /// Process ID of the sender, 0 when the system did not say.
    sender_process: u32,
};

/// Receives Open requests on the App's owner thread. Start it before
/// App.run so the URLs and files that launched the app arrive too: the
/// system sends them while the run loop starts. One listener per process;
/// keep it at a stable address until stop. Linux and Windows return
/// UnsupportedCapability.
pub const OpenListener = struct {
    context: *anyopaque,
    on_open: *const fn (*anyopaque, Open) void,
    app: ?*z.App = null,

    pub fn start(self: *OpenListener, app: *z.App) !void {
        app.assertOwner();
        if (comptime !capabilities.open_events) return error.UnsupportedCapability;
        if (self.app != null) return error.AlreadyStarted;
        if (active_listener != null or zsm_open_start(self, delivered) == 0) return error.ListenerActive;
        active_listener = self;
        self.app = app;
    }
    /// Idempotent. Later requests go to the system's default handling.
    pub fn stop(self: *OpenListener) void {
        const app = self.app orelse return;
        app.assertOwner();
        if (comptime capabilities.open_events) zsm_open_stop();
        active_listener = null;
        self.app = null;
    }

    fn delivered(owner: ?*anyopaque, kind: c_int, items: [*]const [*:0]const u8, count: usize, sender: c_int) callconv(.c) void {
        const self: *OpenListener = @ptrCast(@alignCast(owner.?));
        if (self.app == null) return;
        var slices: [max_arguments][]const u8 = undefined;
        var at: usize = 0;
        while (at < count) {
            const batch = @min(count - at, slices.len);
            for (items[at..][0..batch], slices[0..batch]) |item, *slice| slice.* = std.mem.span(item);
            self.on_open(self.context, .{ .kind = if (kind == 0) .urls else .files, .items = slices[0..batch], .sender_process = if (sender > 0) @intCast(sender) else 0 });
            at += batch;
        }
    }
};
var active_listener: ?*OpenListener = null;
extern fn zsm_open_start(owner: *anyopaque, callback: *const fn (?*anyopaque, c_int, [*]const [*:0]const u8, usize, c_int) callconv(.c) void) c_int;
extern fn zsm_open_stop() void;
extern fn zsm_open_simulate(kind: c_int, item: [*:0]const u8) c_int;

/// Integration checks: dispatches the Apple Event the system sends for a
/// URL or a file through the process's handler table, which calls a started
/// OpenListener during this call; call it from inside App.run.
pub fn simulateOpenForTesting(kind: @FieldType(Open, "kind"), item: [:0]const u8) !void {
    if (comptime !capabilities.open_events) return error.UnsupportedCapability;
    if (zsm_open_simulate(@intFromBool(kind == .files), item.ptr) == 0) return error.SimulationFailed;
}

/// Acquire the per-user lock for `options.id`. Exactly one live process is the
/// primary; others receive a Secondary that can forward once. Call this before
/// creating windows. It does not start a thread or touch an App.
pub fn claim(options: Options) !Claim {
    try validateOptions(options);
    return backend.claim(options);
}

/// Claims the lock or forwards `outgoing` to the current primary. A primary
/// that is shutting down may refuse a connection after a secondary saw its
/// lock; the claim is then retried, at most `attempts` times with a short
/// increasing sleep. This blocks the caller and is meant for process start,
/// before App.init. Returns null after a successful forward.
pub fn claimOrForward(options: Options, outgoing: Outgoing, attempts: u8) !?Primary {
    if (attempts == 0 or attempts > 16) return error.InvalidAttempts;
    try validateOutgoing(outgoing);
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        switch (try claim(options)) {
            .primary => |primary| return primary,
            .secondary => |value| {
                var secondary = value;
                defer secondary.deinit();
                if (secondary.forward(outgoing)) |_| return null else |err| switch (err) {
                    error.PrimaryUnavailable => if (attempt + 1 >= attempts) return err,
                    else => return err,
                }
            },
        }
        zio.sleep(@as(u64, attempt + 1) * 20 * std.time.ns_per_ms);
    }
}

/// Owns the OS lock and the listening endpoint. Do not copy after claim.
/// `receive` runs on one application-created worker at a time; `requestStop`
/// may run on any thread; `deinit` runs after receive has returned for the
/// last time (join the worker first).
pub const Primary = struct {
    native: backend.Primary,
    timeout_ms: u32,
    receiving: std.atomic.Value(bool) = .init(false),

    /// Blocks until a peer exchange finishes or requestStop is called. The
    /// peer is acknowledged only after its whole message validated; the
    /// application then decides what activation means (show/focus a window,
    /// open the forwarded files) after posting the copy it needs to App.
    pub fn receive(self: *Primary, storage: []u8, arguments: [][]const u8) !Received {
        if (storage.len < receive_storage_bytes or arguments.len < max_arguments) return error.ResultCapacityExceeded;
        if (self.receiving.swap(true, .acq_rel)) return error.ReceiveAlreadyActive;
        defer self.receiving.store(false, .release);
        return backend.receive(&self.native, self.timeout_ms, storage, arguments);
    }
    pub fn requestStop(self: *Primary) void {
        backend.requestStop(&self.native);
    }
    pub fn deinit(self: *Primary) void {
        std.debug.assert(!self.receiving.load(.acquire));
        backend.deinitPrimary(&self.native);
        self.* = undefined;
    }
};

pub const Secondary = struct {
    native: backend.Secondary,
    timeout_ms: u32,
    sent: bool = false,

    /// Sends one message and waits, bounded by Options.timeout_ms, until the
    /// primary validated and acknowledged it. On Windows the primary is also
    /// allowed to take the foreground. PrimaryUnavailable means the primary
    /// exited or is exiting; claim again.
    pub fn forward(self: *Secondary, outgoing: Outgoing) !void {
        if (self.sent) return error.AlreadyForwarded;
        try validateOutgoing(outgoing);
        var buffer: [receive_storage_bytes]u8 = undefined;
        const frame = try encode(&buffer, outgoing);
        self.sent = true;
        return backend.forward(&self.native, self.timeout_ms, frame);
    }
    pub fn deinit(self: *Secondary) void {
        backend.deinitSecondary(&self.native);
        self.* = undefined;
    }
};

/// Integration checks only: sends bytes without validating or framing them and
/// reports the primary's answer like forward does.
pub const testing = struct {
    pub fn sendRaw(secondary: *Secondary, bytes: []const u8) !void {
        if (secondary.sent) return error.AlreadyForwarded;
        secondary.sent = true;
        return backend.forward(&secondary.native, secondary.timeout_ms, bytes);
    }
};

fn validateOptions(options: Options) !void {
    try identity.validate(options.id);
    if (options.timeout_ms == 0 or options.timeout_ms > 60_000) return error.InvalidTimeout;
}
fn validateOutgoing(outgoing: Outgoing) !void {
    if (outgoing.arguments.len > max_arguments) return error.TooManyArguments;
    var total: usize = 4 + outgoing.cwd.len;
    try validateString(outgoing.cwd);
    for (outgoing.arguments) |argument| {
        try validateString(argument);
        total += 4 + argument.len;
    }
    if (total > max_payload_bytes) return error.MessageTooLarge;
}
fn validateString(value: []const u8) !void {
    if (value.len > max_argument_bytes) return error.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
}

/// Frame: magic, little-endian payload length, string count (cwd + arguments),
/// reserved zero, then each string as u32 length and bytes.
pub fn encode(buffer: []u8, outgoing: Outgoing) ![]u8 {
    try validateOutgoing(outgoing);
    var used: usize = header_bytes;
    try put(buffer, &used, outgoing.cwd);
    for (outgoing.arguments) |argument| try put(buffer, &used, argument);
    @memcpy(buffer[0..4], &magic);
    std.mem.writeInt(u32, buffer[4..8], @intCast(used - header_bytes), .little);
    std.mem.writeInt(u32, buffer[8..12], @intCast(outgoing.arguments.len + 1), .little);
    std.mem.writeInt(u32, buffer[12..16], 0, .little);
    return buffer[0..used];
}
fn put(buffer: []u8, used: *usize, value: []const u8) !void {
    if (buffer.len < used.* + 4 + value.len) return error.ResultCapacityExceeded;
    std.mem.writeInt(u32, buffer[used.*..][0..4], @intCast(value.len), .little);
    @memcpy(buffer[used.* + 4 ..][0..value.len], value);
    used.* += 4 + value.len;
}
/// Validates a header and returns the payload length that follows it.
pub fn payloadLength(header: *const [header_bytes]u8) !usize {
    if (!std.mem.eql(u8, header[0..4], &magic)) return error.Malformed;
    if (std.mem.readInt(u32, header[12..16], .little) != 0) return error.Malformed;
    const count = std.mem.readInt(u32, header[8..12], .little);
    if (count == 0 or count > max_arguments + 1) return error.TooLarge;
    const length = std.mem.readInt(u32, header[4..8], .little);
    if (length > max_payload_bytes) return error.TooLarge;
    if (length < count * 4) return error.Malformed;
    return length;
}
/// Decodes a complete frame; every byte must be consumed exactly.
pub fn decode(frame: []const u8, arguments: [][]const u8, sender: u32) !Message {
    if (frame.len < header_bytes) return error.Malformed;
    const length = try payloadLength(frame[0..header_bytes]);
    if (frame.len != header_bytes + length) return error.Malformed;
    const count = std.mem.readInt(u32, frame[8..12], .little);
    if (arguments.len + 1 < count) return error.ResultCapacityExceeded;
    var at: usize = header_bytes;
    var cwd: []const u8 = undefined;
    for (0..count) |index| {
        if (frame.len - at < 4) return error.Malformed;
        const size = std.mem.readInt(u32, frame[at..][0..4], .little);
        at += 4;
        if (size > max_argument_bytes) return error.TooLarge;
        if (frame.len - at < size) return error.Malformed;
        const value = frame[at..][0..size];
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.Malformed;
        at += size;
        if (index == 0) cwd = value else arguments[index - 1] = value;
    }
    if (at != frame.len) return error.Malformed;
    return .{ .cwd = cwd, .arguments = arguments[0 .. count - 1], .sender_process = sender };
}
fn rejection(err: anyerror) ?Rejection {
    return switch (err) {
        error.Malformed => .malformed,
        error.TooLarge => .too_large,
        error.Timeout => .timeout,
        error.ForeignUser => .foreign_user,
        error.Disconnected => .disconnected,
        else => null,
    };
}

const backend = switch (builtin.os.tag) {
    .linux, .macos => Linux,
    .windows => Windows,
    else => Unsupported,
};

const Unsupported = struct {
    const Primary = struct {};
    const Secondary = struct {};
    fn claim(_: Options) !Claim {
        return error.UnsupportedCapability;
    }
    fn receive(_: *@This().Primary, _: u32, _: []u8, _: [][]const u8) !Received {
        return error.UnsupportedCapability;
    }
    fn requestStop(_: *@This().Primary) void {}
    fn deinitPrimary(_: *@This().Primary) void {}
    fn forward(_: *@This().Secondary, _: u32, _: []const u8) error{ UnsupportedCapability, PrimaryUnavailable }!void {
        return error.UnsupportedCapability;
    }
    fn deinitSecondary(_: *@This().Secondary) void {}
};

/// Unix sockets and flock, on Linux and macOS.
const Linux = struct {
    const posix = std.posix;
    const linux = std.os.linux;
    const darwin = builtin.os.tag == .macos;
    const Primary = struct {
        lock: posix.fd_t,
        listener: posix.fd_t,
        stop_read: posix.fd_t,
        stop_write: posix.fd_t,
        socket_path: @FieldType(posix.sockaddr.un, "path"),
        socket_path_len: usize,
    };
    const Secondary = struct { address: posix.sockaddr.un, length: posix.socklen_t };
    /// struct ucred from SO_PEERCRED.
    const Credentials = extern struct { pid: i32, uid: u32, gid: u32 };

    fn uid() posix.uid_t {
        return if (darwin) std.c.getuid() else linux.getuid();
    }
    /// The per-user runtime directory: $XDG_RUNTIME_DIR on Linux, the
    /// confstr(_CS_DARWIN_USER_TEMP_DIR) folder on macOS.
    fn runtimeDirectory(buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
        if (darwin) {
            const darwin_user_temp_dir = 65537;
            const length = confstr(darwin_user_temp_dir, buffer, buffer.len);
            if (length == 0 or length > buffer.len) return error.RuntimeDirectoryUnavailable;
            var path = buffer[0 .. length - 1];
            while (path.len > 1 and path[path.len - 1] == '/') path.len -= 1;
            return path;
        }
        return zio.getenv("XDG_RUNTIME_DIR") orelse error.RuntimeDirectoryUnavailable;
    }
    extern "c" fn confstr(name: c_int, buffer: [*]u8, length: usize) usize;
    extern "c" fn getpeereid(socket: c_int, euid: *posix.uid_t, egid: *posix.gid_t) c_int;
    /// A non-blocking, close-on-exec Unix stream socket; on macOS without
    /// SIGPIPE, since send there has no MSG_NOSIGNAL.
    fn streamSocket() !posix.fd_t {
        if (comptime darwin) {
            const socket = try zio.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            errdefer zio.posix.close(socket);
            try configure(socket);
            return socket;
        }
        return zio.posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    }
    fn configure(socket: posix.fd_t) !void {
        _ = try zio.posix.fcntl(socket, posix.F.SETFD, posix.FD_CLOEXEC);
        const flags = try zio.posix.fcntl(socket, posix.F.GETFL, 0);
        _ = try zio.posix.fcntl(socket, posix.F.SETFL, flags | @as(usize, @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))));
        const on: c_int = 1;
        if (std.c.setsockopt(socket, posix.SOL.SOCKET, std.c.SO.NOSIGPIPE, std.mem.asBytes(&on), @sizeOf(c_int)) != 0) return error.SocketConfigurationFailed;
    }
    fn acceptPeer(listener: posix.fd_t) !posix.fd_t {
        if (comptime darwin) {
            const rc = std.c.accept(listener, null, null);
            if (rc < 0) return switch (std.c.errno(rc)) {
                .AGAIN, .INTR => error.WouldBlock,
                .CONNABORTED => error.ConnectionAborted,
                else => error.Unexpected,
            };
            errdefer zio.posix.close(rc);
            try configure(rc);
            return rc;
        }
        return zio.posix.accept(listener, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
    }
    /// The peer's uid and process ID.
    fn peerOf(socket: posix.fd_t) !struct { uid: posix.uid_t, pid: u32 } {
        if (comptime darwin) {
            var euid: posix.uid_t = undefined;
            var egid: posix.gid_t = undefined;
            if (getpeereid(socket, &euid, &egid) != 0) return error.PeerCredentialsUnavailable;
            // SOL_LOCAL, LOCAL_PEERPID
            var pid: c_int = 0;
            var size: posix.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(socket, 0, 2, @ptrCast(&pid), &size) != 0) return error.PeerCredentialsUnavailable;
            return .{ .uid = euid, .pid = @intCast(pid) };
        }
        var credentials: Credentials = undefined;
        var size: posix.socklen_t = @sizeOf(Credentials);
        if (linux.errno(linux.getsockopt(socket, posix.SOL.SOCKET, posix.SO.PEERCRED, @ptrCast(&credentials), &size)) != .SUCCESS) return error.PeerCredentialsUnavailable;
        return .{ .uid = credentials.uid, .pid = @intCast(credentials.pid) };
    }
    const send_flags: u32 = if (darwin) 0 else posix.MSG.NOSIGNAL;

    const Paths = struct {
        lock: [std.fs.max_path_bytes:0]u8 = undefined,
        socket: posix.sockaddr.un = .{ .path = @splat(0) },
        socket_len: usize = 0,
    };
    fn paths(id: []const u8) !Paths {
        var runtime_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const runtime = try runtimeDirectory(&runtime_buffer);
        if (runtime.len == 0 or runtime[0] != '/') return error.RuntimeDirectoryUnavailable;
        // The runtime directory is the user isolation boundary: it must be a
        // directory owned by this user and closed to everyone else.
        const directory = zio.posix.open(runtime, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return error.RuntimeDirectoryUnavailable;
        defer zio.posix.close(directory);
        const status = zio.posix.fstat(directory) catch return error.RuntimeDirectoryUnavailable;
        if (status.uid != uid() or status.mode & 0o077 != 0) return error.RuntimeDirectoryUnsafe;
        var result: Paths = .{};
        const lock = std.fmt.bufPrintSentinel(&result.lock, "{s}/ziggurat-instance-{s}.lock", .{ runtime, id }, 0) catch return error.PathTooLong;
        _ = lock;
        // macOS socket paths hold 103 bytes; a longer one names the ID by hash.
        const socket = std.fmt.bufPrint(&result.socket.path, "{s}/ziggurat-instance-{s}.sock", .{ runtime, id }) catch if (darwin)
            std.fmt.bufPrint(&result.socket.path, "{s}/ziggurat-instance-{x:0>16}.sock", .{ runtime, std.hash.Wyhash.hash(0, id) }) catch return error.PathTooLong
        else
            return error.PathTooLong;
        if (socket.len >= result.socket.path.len) return error.PathTooLong;
        result.socket_len = socket.len;
        return result;
    }
    fn claim(options: Options) !Claim {
        var p = try paths(options.id);
        const lock = try zio.posix.open(std.mem.sliceTo(&p.lock, 0), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        errdefer zio.posix.close(lock);
        zio.posix.flock(lock, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => {
                zio.posix.close(lock);
                const length: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + p.socket_len + 1);
                return .{ .secondary = .{ .native = .{ .address = p.socket, .length = length }, .timeout_ms = options.timeout_ms } };
            },
            else => return err,
        };
        // The lock owner may replace a socket left behind by a crashed primary.
        std.Io.Dir.cwd().deleteFile(zio.io(), p.socket.path[0..p.socket_len]) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const listener = try streamSocket();
        errdefer zio.posix.close(listener);
        try zio.posix.bind(listener, @ptrCast(&p.socket), @intCast(@offsetOf(posix.sockaddr.un, "path") + p.socket_len + 1));
        errdefer std.Io.Dir.cwd().deleteFile(zio.io(), p.socket.path[0..p.socket_len]) catch {};
        try zio.posix.listen(listener, 8);
        const stop = try zio.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        var primary: @This().Primary = .{ .lock = lock, .listener = listener, .stop_read = stop[0], .stop_write = stop[1], .socket_path = undefined, .socket_path_len = p.socket_len };
        @memcpy(primary.socket_path[0 .. p.socket_len + 1], p.socket.path[0 .. p.socket_len + 1]);
        return .{ .primary = .{ .native = primary, .timeout_ms = options.timeout_ms } };
    }
    fn requestStop(self: *@This().Primary) void {
        _ = zio.posix.write(self.stop_write, "s") catch {};
    }
    fn stopped(self: *@This().Primary) bool {
        var fds = [_]posix.pollfd{.{ .fd = self.stop_read, .events = posix.POLL.IN, .revents = 0 }};
        return (posix.poll(&fds, 0) catch 0) != 0;
    }
    fn deinitPrimary(self: *@This().Primary) void {
        zio.posix.close(self.listener);
        std.Io.Dir.cwd().deleteFile(zio.io(), self.socket_path[0..self.socket_path_len]) catch {};
        zio.posix.close(self.stop_read);
        zio.posix.close(self.stop_write);
        // Closing the descriptor releases the flock; the lock file stays so a
        // concurrent claimer never locks an unlinked inode.
        zio.posix.close(self.lock);
    }
    fn receive(self: *@This().Primary, timeout_ms: u32, storage: []u8, arguments: [][]const u8) !Received {
        while (true) {
            var fds = [_]posix.pollfd{
                .{ .fd = self.listener, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_read, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = try posix.poll(&fds, -1);
            if (fds[1].revents != 0) return .stopped;
            if (fds[0].revents == 0) continue;
            const connection = acceptPeer(self.listener) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => return err,
            };
            defer zio.posix.close(connection);
            const credentials = try peerOf(connection);
            if (credentials.uid != uid()) return .{ .rejected = .foreign_user };
            const deadline = zio.milliTimestamp() + timeout_ms;
            const message = exchange(self, connection, deadline, storage, arguments, credentials.pid) catch |err| {
                if (err == error.Stopped) return .stopped;
                const reason = rejection(err) orelse return err;
                if (reason != .disconnected and reason != .timeout) writeAll(self, connection, &.{ack_rejected}, deadline) catch {};
                return .{ .rejected = reason };
            };
            writeAll(self, connection, &.{ack_accepted}, deadline) catch |err| {
                if (err == error.Stopped) return .stopped;
                return .{ .rejected = rejection(err) orelse return err };
            };
            return .{ .message = message };
        }
    }
    fn exchange(self: *@This().Primary, peer: posix.fd_t, deadline: i64, storage: []u8, arguments: [][]const u8, sender: u32) !Message {
        try readAll(self, peer, storage[0..header_bytes], deadline);
        const length = try payloadLength(storage[0..header_bytes]);
        try readAll(self, peer, storage[header_bytes..][0..length], deadline);
        return decode(storage[0 .. header_bytes + length], arguments, sender);
    }
    fn waitFor(self: ?*@This().Primary, fd: posix.fd_t, events: i16, deadline: i64) !void {
        while (true) {
            const remaining = deadline - zio.milliTimestamp();
            if (remaining <= 0) return error.Timeout;
            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = events, .revents = 0 },
                .{ .fd = if (self) |primary| primary.stop_read else -1, .events = posix.POLL.IN, .revents = 0 },
            };
            if (try posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) == 0) return error.Timeout;
            if (fds[1].revents != 0) return error.Stopped;
            if (fds[0].revents != 0) return;
        }
    }
    fn readAll(self: ?*@This().Primary, fd: posix.fd_t, buffer: []u8, deadline: i64) !void {
        var at: usize = 0;
        while (at < buffer.len) {
            try waitFor(self, fd, posix.POLL.IN, deadline);
            const count = posix.read(fd, buffer[at..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer => return error.Disconnected,
                else => return err,
            };
            if (count == 0) return error.Disconnected;
            at += count;
        }
    }
    fn writeAll(self: ?*@This().Primary, fd: posix.fd_t, bytes: []const u8, deadline: i64) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            try waitFor(self, fd, posix.POLL.OUT, deadline);
            at += zio.posix.send(fd, bytes[at..], send_flags) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.BrokenPipe, error.ConnectionResetByPeer => return error.Disconnected,
                else => return err,
            };
        }
    }
    fn forward(self: *@This().Secondary, timeout_ms: u32, frame: []const u8) !void {
        const socket = try streamSocket();
        defer zio.posix.close(socket);
        const deadline = zio.milliTimestamp() + timeout_ms;
        // A full backlog makes a non-blocking Unix connect fail with EAGAIN
        // instead of waiting, so a primary that stopped accepting is bounded.
        while (true) {
            if (zio.posix.connect(socket, @ptrCast(&self.address), self.length)) |_| break else |err| switch (err) {
                error.FileNotFound, error.ConnectionRefused => return error.PrimaryUnavailable,
                error.WouldBlock => {
                    if (zio.milliTimestamp() >= deadline) return error.Timeout;
                    zio.sleep(5 * std.time.ns_per_ms);
                },
                else => return err,
            }
        }
        writeAll(null, socket, frame, deadline) catch |err| return if (err == error.Disconnected) error.PrimaryUnavailable else err;
        var ack: [1]u8 = undefined;
        readAll(null, socket, &ack, deadline) catch |err| return if (err == error.Disconnected) error.PrimaryUnavailable else err;
        if (ack[0] != ack_accepted) return error.Rejected;
    }
    fn deinitSecondary(_: *@This().Secondary) void {}
};

const Windows = struct {
    const Primary = struct {
        pipe: win.HANDLE,
        io: win.HANDLE,
        stop: win.HANDLE,
        user: [max_sid_bytes]u8 align(8),
    };
    const Secondary = struct {
        name: [pipe_name_units:0]u16,
        user: [max_sid_bytes]u8 align(8),
    };
    const max_sid_bytes = 68;
    const pipe_name_units = 256;
    const buffer_bytes = 4096;

    fn currentUser(destination: *[max_sid_bytes]u8) !void {
        var token: win.HANDLE = null;
        if (win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) == 0) return error.UserIdentityUnavailable;
        defer _ = win.CloseHandle(token);
        try tokenUser(token, destination);
    }
    fn tokenUser(token: win.HANDLE, destination: *[max_sid_bytes]u8) !void {
        var storage: [256]u8 align(8) = undefined;
        var size: win.DWORD = 0;
        if (win.GetTokenInformation(token, win.TokenUser, &storage, storage.len, &size) == 0) return error.UserIdentityUnavailable;
        const user: *const win.TOKEN_USER = @ptrCast(@alignCast(&storage));
        const length = win.GetLengthSid(user.User.Sid);
        if (length > max_sid_bytes or win.CopySid(max_sid_bytes, destination, user.User.Sid) == 0) return error.UserIdentityUnavailable;
    }
    fn processUser(process_id: win.ULONG, destination: *[max_sid_bytes]u8) !void {
        const process = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) orelse return error.ForeignUser;
        defer _ = win.CloseHandle(process);
        var token: win.HANDLE = null;
        if (win.OpenProcessToken(process, win.TOKEN_QUERY, &token) == 0) return error.ForeignUser;
        defer _ = win.CloseHandle(token);
        tokenUser(token, destination) catch return error.ForeignUser;
    }
    /// \\.\pipe\ziggurat-instance-<user SID>-<session>-<id>
    fn pipeName(destination: *[pipe_name_units:0]u16, user: *[max_sid_bytes]u8, id: []const u8) !void {
        var sid_text: win.LPWSTR = null;
        if (win.ConvertSidToStringSidW(user, &sid_text) == 0) return error.UserIdentityUnavailable;
        defer _ = win.LocalFree(sid_text);
        var session: win.DWORD = 0;
        if (win.ProcessIdToSessionId(win.GetCurrentProcessId(), &session) == 0) return error.UserIdentityUnavailable;
        var utf8: [pipe_name_units * 3]u8 = undefined;
        var sid_utf8: [192]u8 = undefined;
        const sid_units = std.mem.sliceTo(sid_text, 0);
        const sid_len = std.unicode.utf16LeToUtf8(&sid_utf8, sid_units) catch return error.UserIdentityUnavailable;
        const text = std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\ziggurat-instance-{s}-{d}-{s}", .{ sid_utf8[0..sid_len], session, id }) catch return error.PathTooLong;
        const units = std.unicode.utf8ToUtf16Le(destination[0..pipe_name_units], text) catch return error.PathTooLong;
        if (units >= pipe_name_units) return error.PathTooLong;
        destination[units] = 0;
    }
    fn claim(options: Options) !Claim {
        var user: [max_sid_bytes]u8 align(8) = undefined;
        try currentUser(&user);
        var name: [pipe_name_units:0]u16 = undefined;
        try pipeName(&name, &user, options.id);
        var sid_text: win.LPWSTR = null;
        if (win.ConvertSidToStringSidW(&user, &sid_text) == 0) return error.UserIdentityUnavailable;
        defer _ = win.LocalFree(sid_text);
        // Protected DACL: only this user may open the pipe.
        var sddl: [160]u16 = undefined;
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
        const sid_units = std.mem.sliceTo(sid_text, 0);
        if (prefix.len + sid_units.len + 2 > sddl.len) return error.UserIdentityUnavailable;
        @memcpy(sddl[0..prefix.len], prefix);
        @memcpy(sddl[prefix.len..][0..sid_units.len], sid_units);
        sddl[prefix.len + sid_units.len] = ')';
        sddl[prefix.len + sid_units.len + 1] = 0;
        var descriptor: win.PSECURITY_DESCRIPTOR = null;
        if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, win.SDDL_REVISION_1, &descriptor, null) == 0) return error.SecurityDescriptorFailed;
        defer _ = win.LocalFree(descriptor);
        var attributes: win.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(win.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = descriptor, .bInheritHandle = 0 };
        const open_mode: win.DWORD = win.PIPE_ACCESS_DUPLEX | win.FILE_FLAG_OVERLAPPED | win.FILE_FLAG_FIRST_PIPE_INSTANCE;
        const pipe_mode: win.DWORD = win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS;
        const pipe = win.CreateNamedPipeW(&name, open_mode, pipe_mode, 1, buffer_bytes, buffer_bytes, 0, &attributes);
        if (pipe == win.INVALID_HANDLE_VALUE) {
            const code = win.GetLastError();
            // The first-instance flag fails with access denied while another
            // live pipe owns the name.
            if (code == win.ERROR_ACCESS_DENIED or code == win.ERROR_PIPE_BUSY) {
                return .{ .secondary = .{ .native = .{ .name = name, .user = user }, .timeout_ms = options.timeout_ms } };
            }
            return error.InstanceLockFailed;
        }
        errdefer _ = win.CloseHandle(pipe);
        const io = win.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        errdefer _ = win.CloseHandle(io);
        const stop = win.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        return .{ .primary = .{ .native = .{ .pipe = pipe, .io = io, .stop = stop, .user = user }, .timeout_ms = options.timeout_ms } };
    }
    fn requestStop(self: *@This().Primary) void {
        _ = win.SetEvent(self.stop);
    }
    fn deinitPrimary(self: *@This().Primary) void {
        _ = win.CloseHandle(self.pipe);
        _ = win.CloseHandle(self.io);
        _ = win.CloseHandle(self.stop);
    }
    fn remaining(deadline: u64) win.DWORD {
        const now = win.GetTickCount64();
        return if (now >= deadline) 0 else @intCast(@min(deadline - now, std.math.maxInt(win.DWORD) - 1));
    }
    /// Completes one overlapped operation that was just started. Cancels and
    /// drains it on timeout or stop so the OVERLAPPED never outlives the call.
    fn complete(handle: win.HANDLE, overlapped: *win.OVERLAPPED, started: win.BOOL, stop: ?win.HANDLE, timeout: win.DWORD) !win.DWORD {
        var bytes: win.DWORD = 0;
        if (started == 0) switch (win.GetLastError()) {
            win.ERROR_IO_PENDING => {},
            win.ERROR_PIPE_CONNECTED => return 0,
            win.ERROR_BROKEN_PIPE, win.ERROR_NO_DATA, win.ERROR_PIPE_NOT_CONNECTED => return error.Disconnected,
            else => return error.PipeIoFailed,
        };
        var handles = [2]win.HANDLE{ overlapped.hEvent, stop orelse null };
        const count: win.DWORD = if (stop == null) 1 else 2;
        const signalled = win.WaitForMultipleObjects(count, &handles, 0, timeout);
        if (signalled != win.WAIT_OBJECT_0) {
            _ = win.CancelIoEx(handle, overlapped);
            _ = win.GetOverlappedResult(handle, overlapped, &bytes, 1);
            return if (signalled == win.WAIT_OBJECT_0 + 1) error.Stopped else if (signalled == win.WAIT_TIMEOUT) error.Timeout else error.PipeIoFailed;
        }
        if (win.GetOverlappedResult(handle, overlapped, &bytes, 0) == 0) return switch (win.GetLastError()) {
            win.ERROR_BROKEN_PIPE, win.ERROR_NO_DATA, win.ERROR_PIPE_NOT_CONNECTED, win.ERROR_OPERATION_ABORTED => error.Disconnected,
            else => error.PipeIoFailed,
        };
        return bytes;
    }
    fn readAll(handle: win.HANDLE, event: win.HANDLE, stop: ?win.HANDLE, buffer: []u8, deadline: u64) !void {
        var at: usize = 0;
        while (at < buffer.len) {
            var overlapped = std.mem.zeroes(win.OVERLAPPED);
            overlapped.hEvent = event;
            const chunk: win.DWORD = @intCast(@min(buffer.len - at, buffer_bytes));
            const started = win.ReadFile(handle, buffer[at..].ptr, chunk, null, &overlapped);
            const count = try complete(handle, &overlapped, started, stop, remaining(deadline));
            if (count == 0) return error.Disconnected;
            at += count;
        }
    }
    fn writeAll(handle: win.HANDLE, event: win.HANDLE, stop: ?win.HANDLE, bytes: []const u8, deadline: u64) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            var overlapped = std.mem.zeroes(win.OVERLAPPED);
            overlapped.hEvent = event;
            const chunk: win.DWORD = @intCast(@min(bytes.len - at, buffer_bytes));
            const started = win.WriteFile(handle, bytes[at..].ptr, chunk, null, &overlapped);
            at += try complete(handle, &overlapped, started, stop, remaining(deadline));
        }
    }
    fn receive(self: *@This().Primary, timeout_ms: u32, storage: []u8, arguments: [][]const u8) !Received {
        while (true) {
            if (win.WaitForSingleObject(self.stop, 0) == win.WAIT_OBJECT_0) return .stopped;
            var overlapped = std.mem.zeroes(win.OVERLAPPED);
            overlapped.hEvent = self.io;
            const started = win.ConnectNamedPipe(self.pipe, &overlapped);
            _ = complete(self.pipe, &overlapped, started, self.stop, win.INFINITE) catch |err| switch (err) {
                error.Stopped => return .stopped,
                error.Disconnected => {
                    _ = win.DisconnectNamedPipe(self.pipe);
                    continue;
                },
                else => return err,
            };
            defer _ = win.DisconnectNamedPipe(self.pipe);
            var client: win.ULONG = 0;
            if (win.GetNamedPipeClientProcessId(self.pipe, &client) == 0) return .{ .rejected = .disconnected };
            var peer: [max_sid_bytes]u8 align(8) = undefined;
            processUser(client, &peer) catch return .{ .rejected = .foreign_user };
            if (win.EqualSid(&peer, &self.user) == 0) return .{ .rejected = .foreign_user };
            const deadline = win.GetTickCount64() + timeout_ms;
            const message = exchange(self, storage, arguments, client, deadline) catch |err| {
                if (err == error.Stopped) return .stopped;
                const reason = rejection(err) orelse return err;
                if (reason != .disconnected and reason != .timeout) writeAll(self.pipe, self.io, self.stop, &.{ack_rejected}, deadline) catch {};
                drain(self, deadline);
                return .{ .rejected = reason };
            };
            writeAll(self.pipe, self.io, self.stop, &.{ack_accepted}, deadline) catch |err| {
                if (err == error.Stopped) return .stopped;
                return .{ .rejected = rejection(err) orelse return err };
            };
            // DisconnectNamedPipe discards unread bytes, so wait for the peer
            // to read the acknowledgement and close its end first.
            drain(self, deadline);
            return .{ .message = message };
        }
    }
    fn drain(self: *@This().Primary, deadline: u64) void {
        var byte: [1]u8 = undefined;
        readAll(self.pipe, self.io, self.stop, &byte, deadline) catch {};
    }
    fn exchange(self: *@This().Primary, storage: []u8, arguments: [][]const u8, sender: u32, deadline: u64) !Message {
        try readAll(self.pipe, self.io, self.stop, storage[0..header_bytes], deadline);
        const length = try payloadLength(storage[0..header_bytes]);
        try readAll(self.pipe, self.io, self.stop, storage[header_bytes..][0..length], deadline);
        return decode(storage[0 .. header_bytes + length], arguments, sender);
    }
    fn forward(self: *@This().Secondary, timeout_ms: u32, frame: []const u8) !void {
        const deadline = win.GetTickCount64() + timeout_ms;
        const pipe = while (true) {
            const handle = win.CreateFileW(&self.name, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, win.FILE_FLAG_OVERLAPPED | win.SECURITY_SQOS_PRESENT | win.SECURITY_IDENTIFICATION, null);
            if (handle != win.INVALID_HANDLE_VALUE) break handle;
            switch (win.GetLastError()) {
                win.ERROR_FILE_NOT_FOUND => return error.PrimaryUnavailable,
                win.ERROR_PIPE_BUSY => {
                    const wait = remaining(deadline);
                    if (wait == 0 or win.WaitNamedPipeW(&self.name, wait) == 0) {
                        return if (win.GetLastError() == win.ERROR_FILE_NOT_FOUND) error.PrimaryUnavailable else error.Timeout;
                    }
                },
                else => return error.PipeIoFailed,
            }
        };
        defer _ = win.CloseHandle(pipe);
        var server: win.ULONG = 0;
        if (win.GetNamedPipeServerProcessId(pipe, &server) == 0) return error.PrimaryUnavailable;
        var owner: [max_sid_bytes]u8 align(8) = undefined;
        processUser(server, &owner) catch return error.ForeignUser;
        if (win.EqualSid(&owner, &self.user) == 0) return error.ForeignUser;
        // The primary normally activates a window in response; foreground
        // rights must be granted by the process that currently holds them.
        _ = win.AllowSetForegroundWindow(server);
        const event = win.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
        defer _ = win.CloseHandle(event);
        writeAll(pipe, event, null, frame, deadline) catch |err| return if (err == error.Disconnected) error.PrimaryUnavailable else err;
        var ack: [1]u8 = undefined;
        readAll(pipe, event, null, &ack, deadline) catch |err| return if (err == error.Disconnected) error.PrimaryUnavailable else err;
        if (ack[0] != ack_accepted) return error.Rejected;
    }
    fn deinitSecondary(_: *@This().Secondary) void {}
};

test "instance frames round trip and reject malformed input" {
    var buffer: [receive_storage_bytes]u8 = undefined;
    const outgoing: Outgoing = .{ .cwd = "/home/user", .arguments = &.{ "", "two words", "中文🦎", "scheme://open?x=1", "\xff\xfe" } };
    const frame = try encode(&buffer, outgoing);
    var arguments: [max_arguments][]const u8 = undefined;
    const message = try decode(frame, &arguments, 42);
    try std.testing.expectEqualStrings("/home/user", message.cwd);
    try std.testing.expectEqual(@as(usize, 5), message.arguments.len);
    for (outgoing.arguments, message.arguments) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(u32, 42), message.sender_process);

    try std.testing.expectError(error.Malformed, decode(frame[0 .. frame.len - 1], &arguments, 0));
    var extended: [receive_storage_bytes]u8 = undefined;
    @memcpy(extended[0..frame.len], frame);
    extended[frame.len] = 0;
    try std.testing.expectError(error.Malformed, decode(extended[0 .. frame.len + 1], &arguments, 0));
    var bad = buffer;
    bad[0] = 'X';
    try std.testing.expectError(error.Malformed, decode(bad[0..frame.len], &arguments, 0));
    bad = buffer;
    std.mem.writeInt(u32, bad[4..8], max_payload_bytes + 1, .little);
    try std.testing.expectError(error.TooLarge, payloadLength(bad[0..header_bytes]));
    bad = buffer;
    std.mem.writeInt(u32, bad[8..12], max_arguments + 2, .little);
    try std.testing.expectError(error.TooLarge, payloadLength(bad[0..header_bytes]));
    bad = buffer;
    std.mem.writeInt(u32, bad[8..12], 0, .little);
    try std.testing.expectError(error.TooLarge, payloadLength(bad[0..header_bytes]));
    bad = buffer;
    std.mem.writeInt(u32, bad[12..16], 1, .little);
    try std.testing.expectError(error.Malformed, payloadLength(bad[0..header_bytes]));
    // A string length that runs past the payload.
    bad = buffer;
    std.mem.writeInt(u32, bad[header_bytes..][0..4], 0xffff, .little);
    try std.testing.expectError(error.TooLarge, decode(bad[0..frame.len], &arguments, 0));
    bad = buffer;
    std.mem.writeInt(u32, bad[header_bytes..][0..4], 200, .little);
    try std.testing.expectError(error.Malformed, decode(bad[0..frame.len], &arguments, 0));
    // NUL inside a forwarded string.
    bad = buffer;
    bad[header_bytes + 4] = 0;
    try std.testing.expectError(error.Malformed, decode(bad[0..frame.len], &arguments, 0));
    try std.testing.expectError(error.ResultCapacityExceeded, decode(frame, arguments[0..2], 0));

    try std.testing.expectError(error.EmbeddedNul, encode(&buffer, .{ .cwd = "a\x00" }));
    var many: [max_arguments + 1][]const u8 = @splat("");
    try std.testing.expectError(error.TooManyArguments, encode(&buffer, .{ .cwd = "/", .arguments = &many }));
    const long: [max_argument_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.ArgumentTooLong, encode(&buffer, .{ .cwd = "/", .arguments = &.{&long} }));
    const part: [max_argument_bytes]u8 = @splat('a');
    try std.testing.expectError(error.MessageTooLarge, encode(&buffer, .{ .cwd = "/", .arguments = &.{ &part, &part, &part, &part } }));
    _ = try encode(&buffer, .{ .cwd = "/", .arguments = &.{ &part, &part, &part, part[0 .. max_argument_bytes - 24] } });
    try std.testing.expectError(error.InvalidTimeout, claim(.{ .id = "org.example.App", .timeout_ms = 0 }));
    try std.testing.expectError(error.InvalidIdentity, claim(.{ .id = "../escape" }));
    try std.testing.expectError(error.InvalidAttempts, claimOrForward(.{ .id = "org.example.App" }, .{ .cwd = "/" }, 0));
}
