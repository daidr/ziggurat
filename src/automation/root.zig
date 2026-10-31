//! Drives a running app from another process: an end-to-end test runner or
//! an agent lists the app's windows, reads what their views show as
//! elements, acts on them, sends pointer, wheel, key and text input,
//! chooses menu items, evaluates scripts in pages, captures windows as PNG
//! images, and waits for them to settle. It speaks newline-delimited JSON
//! over a Unix domain socket that only the user can open; see
//! `docs/automation.md` for the protocol.
//!
//! An app opts in twice: it links this module, which a test build does and
//! a release leaves out, and starts the server only when
//! `ZIGGURAT_AUTOMATION` names the socket's path:
//!
//! ```zig
//! const automation = try ziggurat_automation.start(allocator, app, .{});
//! defer if (automation) |server| server.stop();
//! try app.run();
//! ```
//!
//! Builds without the views' inspector leave it out as they do the
//! inspector: there `start` returns null and says so on standard error.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
pub const protocol = @import("protocol.zig");
pub const names = @import("names.zig");
pub const tree = @import("tree.zig");
pub const png = @import("png.zig");
pub const Driver = @import("driver.zig").Driver;

/// Whether this build has automation: builds with the views' inspector do.
pub const enabled = @import("ziggurat_view").inspector.enabled;
/// The variable naming the socket's path.
pub const variable = "ZIGGURAT_AUTOMATION";

pub const Options = struct {
    /// The socket's path; null reads it from `ZIGGURAT_AUTOMATION`.
    path: ?[]const u8 = null,
};

/// Listens on the socket the options or `ZIGGURAT_AUTOMATION` name and
/// answers its clients until `stop`. Returns null when no path is named,
/// or when this build leaves automation out. Call on the main thread,
/// before `App.run`; the allocator must be thread-safe.
pub fn start(allocator: std.mem.Allocator, app: *z.App, options: Options) !?*Server {
    var owned: ?[]u8 = null;
    defer if (owned) |value| allocator.free(value);
    const path = options.path orelse path: {
        owned = zio.getEnvVarOwned(allocator, variable) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => |other| return other,
        };
        break :path owned.?;
    };
    if (path.len == 0) return null;
    if (comptime !enabled) {
        std.debug.print("ziggurat: automation: this build leaves automation out with the inspector; {s} is ignored\n", .{variable});
        return null;
    }
    return try Server.start(allocator, app, path);
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    driver: Driver,
    path: []u8,
    listener: std.Io.net.Server,
    accept_thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: zio.Mutex = .{},
    connections: std.ArrayList(*Connection) = .empty,

    const Connection = struct {
        server: *Server,
        stream: std.Io.net.Stream,
        thread: std.Thread = undefined,
    };

    fn start(allocator: std.mem.Allocator, app: *z.App, path: []const u8) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        self.* = .{ .allocator = allocator, .driver = .init(allocator, app), .path = owned, .listener = try listen(owned) };
        errdefer self.listener.deinit(zio.io());
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// Stops listening, closes the connections, removes the socket and
    /// frees the server. Call on the main thread after `App.run` returned,
    /// once no request can wait for the main thread.
    pub fn stop(self: *Server) void {
        const io = zio.io();
        self.stopping.store(true, .release);
        // Wake the accepting thread with a connection of our own.
        if (std.Io.net.UnixAddress.init(self.path)) |address| {
            if (address.connect(io)) |stream| stream.close(io) else |_| {}
        } else |_| {}
        self.accept_thread.join();
        self.listener.deinit(io);
        self.mutex.lock();
        const connections = self.connections.items;
        for (connections) |connection| connection.stream.shutdown(io, .both) catch {};
        self.mutex.unlock();
        for (connections) |connection| {
            connection.thread.join();
            connection.stream.close(io);
            self.allocator.destroy(connection);
        }
        self.connections.deinit(self.allocator);
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        self.driver.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *Server) void {
        const io = zio.io();
        while (true) {
            const stream = self.listener.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return,
            };
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                return;
            }
            self.open(stream) catch stream.close(io);
        }
    }
    fn open(self: *Server, stream: std.Io.net.Stream) !void {
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .server = self, .stream = stream };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.ensureUnusedCapacity(self.allocator, 1);
        connection.thread = try std.Thread.spawn(.{}, serve, .{connection});
        self.connections.appendAssumeCapacity(connection);
    }

    /// Answers the requests of a connection in order, each once the one
    /// before it is answered, until the client closes it or the app quits.
    fn serve(connection: *Connection) void {
        const server = connection.server;
        serveStream(server.allocator, server.driver.driver(), connection.stream) catch {};
        // The client sees the end of the stream; `stop` closes the socket.
        connection.stream.shutdown(zio.io(), .both) catch {};
    }
};

/// Answers the lines of `stream` with `driver` until it ends.
pub fn serveStream(allocator: std.mem.Allocator, driver: protocol.Driver, stream: std.Io.net.Stream) !void {
    const io = zio.io();
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    return serveLines(allocator, driver, &reader.interface, &writer.interface);
}

/// Answers each line of `in` on `out`, in order, until `in` ends or the app
/// quits.
pub fn serveLines(allocator: std.mem.Allocator, driver: protocol.Driver, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = in.streamDelimiterLimit(&line.writer, '\n', .limited(protocol.max_line)) catch |err| switch (err) {
            error.StreamTooLong => {
                try protocol.writeTooLong(out);
                try out.flush();
                return;
            },
            else => |other| return other,
        };
        const ended = blk: {
            _ = in.takeByte() catch |err| switch (err) {
                error.EndOfStream => break :blk true,
                else => |other| return other,
            };
            break :blk false;
        };
        const request = std.mem.trim(u8, line.written(), " \t\r");
        if (request.len != 0) {
            _ = arena_state.reset(.retain_capacity);
            protocol.handle(driver, arena_state.allocator(), request, out) catch |err| switch (err) {
                error.Quit => return,
                else => |other| return other,
            };
            try out.flush();
        }
        if (ended) return;
    }
}

/// Listens on the Unix domain socket at `path`, which only the user can
/// open. A socket left there by an app that ended without closing it is
/// replaced; one that an app listens on, or a file that is no socket, is
/// left alone.
pub fn listen(path: []const u8) !std.Io.net.Server {
    const io = zio.io();
    const address = try std.Io.net.UnixAddress.init(path);
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(io, path, .{ .follow_symlinks = false })) |stat| {
        // Windows reports a socket's file as an empty reparse point.
        const socket = if (builtin.os.tag == .windows) stat.size == 0 else stat.kind == .unix_domain_socket;
        if (!socket) return error.NotSocket;
        if (address.connect(io)) |stream| {
            stream.close(io);
            return error.AddressInUse;
        } else |_| {}
        try cwd.deleteFile(io, path);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    }
    // Readable and writable by the user alone from the start: the umask
    // leaves the others out while the socket is made, and its mode after.
    const previous = umask(0o177);
    var server = address.listen(io, .{}) catch |err| {
        _ = umask(previous);
        return err;
    };
    _ = umask(previous);
    errdefer server.deinit(io);
    if (builtin.os.tag != .windows) try cwd.setFilePermissions(io, path, zio.mode(0o600), .{});
    return server;
}

fn umask(mode: u32) u32 {
    if (builtin.os.tag == .windows) return 0;
    if (builtin.os.tag == .linux and !builtin.link_libc) return @truncate(std.os.linux.syscall1(.umask, mode));
    return @intCast(std.c.umask(@intCast(mode)));
}

test {
    _ = names;
    _ = png;
    _ = @import("tests.zig");
}
