//! SQLite plugin: pages open local databases through `@ziggurat/plugin-sqlite`.
//! SQLite is loaded when the plugin starts; statements run on workers the
//! plugin starts in `init` and joins in `deinit`, one operation of a
//! connection at a time, and their results reach the main thread through
//! `App.post`.
const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ziggurat_ipc");
const runtime = @import("ziggurat_page_runtime");
pub const native = @import("sqlite_native.zig");

pub const Service = @import("sqlite_service.zig").Service;
const limits = Service.limits;
const Dispatcher = ipc.Dispatcher(Service, Implementation, Plugin, limits);
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;
const is_windows = builtin.os.tag == .windows;

/// The JSON of one part of rows stays under this.
const part_bytes = 48 * 1024;
const max_connections = 16;

pub const Options = struct {
    post: runtime.Post,
    /// Absolute: the directory database names are in. A missing one is
    /// created for a writable database.
    directory: []const u8,
    /// The SQLite library to load; the system's when null.
    library: ?[]const u8 = null,
    /// Workers the plugin starts in `init` and joins in `deinit`.
    workers: u8 = 2,
    /// How long an operation waits for another connection's lock; a
    /// negative value does not wait.
    busy_timeout_ms: i32 = 5000,
    /// Bytes of rows one query may return.
    max_result_bytes: usize = 64 * 1024 * 1024,
};

const Kind = enum { open, execute, query, transaction, closeDatabase };

const Work = union(Kind) {
    open: ipc.Work(Service, limits, "open"),
    execute: ipc.Work(Service, limits, "execute"),
    query: ipc.Work(Service, limits, "query"),
    transaction: ipc.Work(Service, limits, "transaction"),
    closeDatabase: ipc.Work(Service, limits, "closeDatabase"),

    fn token(self: *const Work) ipc.Token {
        return switch (self.*) {
            inline else => |work| work.token,
        };
    }
    fn deinit(self: *Work) void {
        switch (self.*) {
            inline else => |*work| work.deinit(),
        }
    }
};

const Connection = struct {
    // Main thread, or under the plugin mutex once the connection is open.
    phase: enum { free, opening, open, closing, closed } = .free,
    id: u32 = 0,
    read_only: bool = false,
    /// A worker runs one of its operations.
    busy: bool = false,
    native: native.Connection = undefined,
};

const Failure = struct {
    code: Service.Code,
    message: [256]u8 = undefined,
    len: usize = 0,

    fn of(code: Service.Code, comptime format: []const u8, args: anytype) Failure {
        var failure: Failure = .{ .code = code };
        failure.len = (std.fmt.bufPrint(&failure.message, format, args) catch failure.message[0..failure.message.len]).len;
        return failure;
    }
    fn text(self: *const Failure) []const u8 {
        return self.message[0..self.len];
    }
};

const Job = struct {
    // Main thread.
    live: bool = false,
    work: Work = undefined,
    has_work: bool = false,
    parts_sent: usize = 0,
    // Set before the job is queued.
    connection: ?*Connection = null,
    path: ?[:0]u8 = null,
    // Under the plugin mutex.
    phase: enum { free, queued, running, finished } = .free,
    changed: bool = false,
    // Written by the worker before it finishes the job.
    arena: std.heap.ArenaAllocator = undefined,
    failure: ?Failure = null,
    result: Service.Result = undefined,
    results: []const Service.Result = &.{},
    parts: []const Service.Rows = &.{},
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    options: Options,
    library: ?native.Library = null,
    load_error: ?anyerror = null,
    dispatcher: Dispatcher = .init(unset),
    implementation: Implementation = .{},
    host: ?*runtime.Host = null,
    connections: [max_connections]Connection = @splat(.{}),
    next_id: u32 = 1,
    jobs: [limits.max_pending]Job = @splat(.{}),
    /// Queued jobs in arrival order.
    queue: [limits.max_pending]u16 = undefined,
    queue_len: usize = 0,
    threads: []std.Thread = &.{},
    mutex: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    stopping: bool = false,
    outbox: runtime.Outbox,

    /// Loads SQLite and starts the workers. Without the library the plugin
    /// still starts, and opening a database fails with `unsupported`.
    /// `allocator` must be thread-safe: workers allocate with it.
    pub fn init(self: *Plugin, allocator: std.mem.Allocator, options: Options) !void {
        std.debug.assert(options.workers > 0);
        if (!std.fs.path.isAbsolute(options.directory)) return error.InvalidDirectory;
        self.* = .{ .allocator = allocator, .options = options, .outbox = .{ .post = options.post, .drain = .{ .context = self, .call = drain } } };
        self.library = native.Library.load(options.library) catch |err| blk: {
            self.load_error = err;
            break :blk null;
        };
        errdefer if (self.library) |*library| library.unload();
        self.threads = try allocator.alloc(std.Thread, options.workers);
        var started: usize = 0;
        errdefer {
            self.stop();
            for (self.threads[0..started]) |thread| thread.join();
            allocator.free(self.threads);
        }
        while (started < self.threads.len) : (started += 1) self.threads[started] = try std.Thread.spawn(.{}, worker, .{self});
    }

    /// Main thread, after `App.run` returned and with the Host detached:
    /// cancels operations, joins the workers and closes every connection.
    pub fn deinit(self: *Plugin) void {
        self.stop();
        for (self.threads) |thread| thread.join();
        for (&self.jobs) |*job| {
            job.live = false;
            if (job.phase != .free) self.release(job);
        }
        for (&self.connections) |*connection| {
            if (connection.phase != .free and connection.phase != .opening and connection.phase != .closed) connection.native.close();
            connection.* = .{};
        }
        self.allocator.free(self.threads);
        if (self.library) |*library| library.unload();
        self.* = undefined;
    }

    pub fn plugin(self: *Plugin) runtime.Plugin {
        return .{ .name = Service.name, .endpoint = .{ .context = self, .vtable = &vtable } };
    }

    const vtable: runtime.Endpoint.VTable = .{ .open = open, .receive = receive, .close = close };

    fn stop(self: *Plugin) void {
        self.outbox.stop();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        for (&self.connections) |*connection| if (connection.phase == .open or connection.phase == .closing) connection.native.interrupt();
        self.wake.broadcast();
    }

    fn open(context: *anyopaque, host: *runtime.Host, session: ipc.Session) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.reset(session, &canceled) catch {};
        self.forget();
        self.host = host;
    }

    fn close(context: *anyopaque, _: *runtime.Host) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.close(&canceled) catch unreachable;
        self.forget();
        self.host = null;
    }

    /// The document went: its calls are abandoned and its connections close.
    fn forget(self: *Plugin) void {
        for (&self.jobs) |*job| if (job.live) self.abandon(job);
        self.mutex.lock();
        for (&self.connections) |*connection| self.closeLocked(connection);
        self.wake.broadcast();
        self.mutex.unlock();
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
            .cancel => |token| if (self.find(token)) |job| self.abandon(job),
            .ack => |ack| if (self.find(ack.token)) |job| self.deliver(job),
            .rejected => |rejected| {
                const packet = ipc.protocol.reject(self.allocator, rejected.token, rejected.code, limits.max_message_bytes) catch return;
                defer self.allocator.free(packet);
                host.send(packet) catch {};
            },
        }
    }

    fn find(self: *Plugin, token: ipc.Token) ?*Job {
        for (&self.jobs) |*job| if (job.live) {
            const own = job.work.token();
            if (own.slot == token.slot and own.id == token.id) return job;
        };
        return null;
    }

    /// The page no longer waits: a queued job is dropped, a running one
    /// interrupted. The job is released once its worker lets go of it.
    fn abandon(self: *Plugin, job: *Job) void {
        job.live = false;
        self.mutex.lock();
        switch (job.phase) {
            .queued => {
                self.dequeue(job);
                job.phase = .finished;
            },
            .running => if (job.connection) |connection| {
                if (connection.phase == .open or connection.phase == .closing) connection.native.interrupt();
            },
            else => {},
        }
        const finished = job.phase == .finished;
        self.mutex.unlock();
        if (finished) self.release(job);
    }

    fn release(self: *Plugin, job: *Job) void {
        std.debug.assert(!job.live);
        if (job.has_work) job.work.deinit();
        if (job.path) |path| self.allocator.free(path);
        if (job.has_work) job.arena.deinit();
        // A connection the job was opening and nobody will hear of.
        if (job.connection) |connection| if (std.meta.activeTag(job.work) == .open and job.failure == null and job.phase == .finished) {
            self.mutex.lock();
            self.closeLocked(connection);
            self.wake.broadcast();
            self.mutex.unlock();
        };
        job.* = .{};
    }

    fn send(self: *Plugin, packet: []u8) bool {
        defer self.allocator.free(packet);
        const host = self.host orelse return false;
        // A failed send closes this endpoint before it returns.
        host.send(packet) catch return false;
        return true;
    }

    fn dequeue(self: *Plugin, job: *Job) void {
        const index: u16 = @intCast(job - &self.jobs[0]);
        for (self.queue[0..self.queue_len], 0..) |queued, at| if (queued == index) {
            std.mem.copyForwards(u16, self.queue[at .. self.queue_len - 1], self.queue[at + 1 .. self.queue_len]);
            self.queue_len -= 1;
            return;
        };
    }

    /// Main thread: fails a call at once.
    fn refuse(self: *Plugin, work: *Work, failure: Failure) void {
        const token = work.token();
        const packet = switch (work.*) {
            inline else => |_, tag| self.dispatcher.router.fail(@tagName(tag), self.allocator, token, failure.code, failure.text()),
        } catch {
            work.deinit();
            return;
        };
        work.deinit();
        _ = self.send(packet);
    }

    /// Main thread: queues a call for a worker.
    fn start(self: *Plugin, taken: Work) void {
        var work = taken;
        const job = for (&self.jobs) |*job| {
            if (job.phase == .free) break job;
        } else return self.refuse(&work, .of(.limit, "sqlite: too many operations", .{}));
        if (self.library == null) return self.refuse(&work, .of(.unsupported, "sqlite: the library could not be loaded ({s})", .{@errorName(self.load_error.?)}));
        switch (work) {
            .open => |open_work| {
                const params = open_work.params;
                if (!validName(params.name)) return self.refuse(&work, .of(.denied, "sqlite: database name must be a relative file name in the plugin's directory", .{}));
                const connection = for (&self.connections) |*item| {
                    if (item.phase == .free) break item;
                } else return self.refuse(&work, .of(.limit, "sqlite: too many open databases", .{}));
                job.path = self.pathOf(params.name) catch return self.refuse(&work, .of(.invalid, "sqlite: out of memory", .{}));
                const timeout = self.options.busy_timeout_ms;
                self.mutex.lock();
                connection.* = .{ .phase = .opening, .id = self.next_id, .read_only = params.readOnly, .busy = true, .native = .{ .lib = &self.library.?, .timeout_ms = if (timeout < 0) 0 else @intCast(timeout) } };
                self.mutex.unlock();
                self.next_id +%= 1;
                if (self.next_id == 0) self.next_id = 1;
                job.connection = connection;
            },
            .closeDatabase => {},
            inline .execute, .query, .transaction => |operation| {
                self.mutex.lock();
                const found = self.lookup(operation.params.connection);
                const usable = if (found) |item| item.phase == .open else false;
                self.mutex.unlock();
                if (!usable) return self.refuse(&work, .of(.closed, "sqlite: database is closed", .{}));
                job.connection = found;
            },
        }
        job.work = work;
        job.has_work = true;
        job.live = true;
        job.arena = .init(self.allocator);
        self.mutex.lock();
        if (job.work == .closeDatabase) {
            // Closing twice, or a database already gone, succeeds at once.
            const item = self.lookup(job.work.closeDatabase.params.connection) orelse {
                job.phase = .finished;
                job.changed = true;
                self.mutex.unlock();
                self.outbox.notify();
                return;
            };
            self.closeLocked(item);
            job.connection = item;
        }
        job.phase = .queued;
        self.queue[self.queue_len] = @intCast(job - &self.jobs[0]);
        self.queue_len += 1;
        self.wake.broadcast();
        self.mutex.unlock();
    }

    fn lookup(self: *Plugin, id: u32) ?*Connection {
        for (&self.connections) |*item| if (item.phase != .free and item.phase != .closed and item.id == id) return item;
        return null;
    }

    /// Under the mutex: the connection takes no more operations, what it
    /// runs is interrupted and its queued operations fail as closed; a
    /// worker closes it once it is idle.
    fn closeLocked(self: *Plugin, item: *Connection) void {
        switch (item.phase) {
            .open => {
                item.phase = .closing;
                item.native.interrupt();
            },
            .opening => item.phase = .closing,
            else => return,
        }
        _ = self;
    }

    fn pathOf(self: *Plugin, name: []const u8) ![:0]u8 {
        if (std.mem.eql(u8, name, ":memory:")) return self.allocator.dupeZ(u8, name);
        const joined = try std.fs.path.join(self.allocator, &.{ self.options.directory, name });
        defer self.allocator.free(joined);
        const path = try self.allocator.dupeZ(u8, joined);
        if (is_windows) std.mem.replaceScalar(u8, path, '/', '\\');
        return path;
    }

    /// Main thread, in the posted drain: hands finished work to the page and
    /// frees closed connections.
    fn drain(context: *anyopaque) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        self.outbox.begin();
        var touched: [limits.max_pending]*Job = undefined;
        var count: usize = 0;
        self.mutex.lock();
        for (&self.jobs) |*job| if (job.changed) {
            job.changed = false;
            touched[count] = job;
            count += 1;
        };
        self.mutex.unlock();
        for (touched[0..count]) |job| {
            if (job.live) self.deliver(job) else self.reap(job);
        }
        self.mutex.lock();
        for (&self.connections) |*item| {
            if (item.phase == .closed) item.* = .{};
        }
        self.mutex.unlock();
    }

    fn reap(self: *Plugin, job: *Job) void {
        self.mutex.lock();
        const finished = job.phase == .finished;
        self.mutex.unlock();
        if (finished) self.release(job);
    }

    /// Main thread: sends a finished job's result, a query's rows in parts
    /// while the page has credit.
    fn deliver(self: *Plugin, job: *Job) void {
        self.mutex.lock();
        const finished = job.phase == .finished;
        self.mutex.unlock();
        if (!finished) return;
        const token = job.work.token();
        if (job.failure) |*failure| {
            const packet = switch (job.work) {
                inline else => |_, tag| self.dispatcher.router.fail(@tagName(tag), self.allocator, token, failure.code, failure.text()),
            } catch return self.finish(job);
            self.finish(job);
            _ = self.send(packet);
            return;
        }
        const packet = switch (job.work) {
            .open => self.dispatcher.router.complete("open", self.allocator, token, job.connection.?.id),
            .execute => self.dispatcher.router.complete("execute", self.allocator, token, job.result),
            .transaction => self.dispatcher.router.complete("transaction", self.allocator, token, job.results),
            .closeDatabase => self.dispatcher.router.complete("closeDatabase", self.allocator, token, {}),
            .query => query: {
                while (job.parts_sent < job.parts.len) {
                    const part = self.dispatcher.router.chunk("query", self.allocator, token, job.parts[job.parts_sent]) catch |err| switch (err) {
                        error.Backpressure => return,
                        else => {
                            const failed = self.dispatcher.router.fail("query", self.allocator, token, .limit, "sqlite: a row does not fit in a message") catch return self.finish(job);
                            self.finish(job);
                            _ = self.send(failed);
                            return;
                        },
                    };
                    job.parts_sent += 1;
                    if (!self.send(part)) return;
                }
                break :query self.dispatcher.router.complete("query", self.allocator, token, {});
            },
        } catch return self.finish(job);
        // The page now knows of an opened connection.
        if (std.meta.activeTag(job.work) == .open) job.connection = null;
        self.finish(job);
        _ = self.send(packet);
    }

    fn finish(self: *Plugin, job: *Job) void {
        job.live = false;
        self.release(job);
    }
};

const Implementation = struct {
    pub fn open(_: *Implementation, plugin: *Plugin, work: ipc.Work(Service, limits, "open")) void {
        plugin.start(.{ .open = work });
    }
    pub fn execute(_: *Implementation, plugin: *Plugin, work: ipc.Work(Service, limits, "execute")) void {
        plugin.start(.{ .execute = work });
    }
    pub fn query(_: *Implementation, plugin: *Plugin, work: ipc.Work(Service, limits, "query")) void {
        plugin.start(.{ .query = work });
    }
    pub fn transaction(_: *Implementation, plugin: *Plugin, work: ipc.Work(Service, limits, "transaction")) void {
        plugin.start(.{ .transaction = work });
    }
    pub fn closeDatabase(_: *Implementation, plugin: *Plugin, work: ipc.Work(Service, limits, "closeDatabase")) void {
        plugin.start(.{ .closeDatabase = work });
    }
};

/// Worker: closes idle connections that are closing, and runs the first
/// queued job whose connection is idle.
fn worker(self: *Plugin) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    while (true) {
        if (self.stopping) return;
        if (closable(self)) |item| {
            item.busy = true;
            self.mutex.unlock();
            item.native.close();
            self.mutex.lock();
            item.busy = false;
            item.phase = .closed;
            // A close call waiting for it, and the drain that frees it.
            for (&self.jobs) |*job| if (job.connection == item and job.phase == .queued and std.meta.activeTag(job.work) == .closeDatabase) {
                self.dequeue(job);
                job.phase = .finished;
                job.changed = true;
            };
            self.mutex.unlock();
            self.outbox.notify();
            self.mutex.lock();
            continue;
        }
        const job = runnable(self) orelse {
            self.wake.wait(&self.mutex);
            continue;
        };
        self.dequeue(job);
        job.phase = .running;
        const item = job.connection;
        if (item) |c| c.busy = true;
        self.mutex.unlock();
        run(self, job);
        self.mutex.lock();
        if (item) |c| {
            c.busy = false;
            if (std.meta.activeTag(job.work) == .open) {
                if (job.failure == null and c.phase == .opening) c.phase = .open;
                if (job.failure != null) c.phase = .closed;
            }
        }
        job.phase = .finished;
        job.changed = true;
        self.wake.broadcast();
        self.mutex.unlock();
        self.outbox.notify();
        self.mutex.lock();
    }
}

fn closable(self: *Plugin) ?*Connection {
    for (&self.connections) |*item| if (item.phase == .closing and !item.busy) {
        // An opening connection closes once its open has run.
        if (item.native.db == null) {
            var opening = false;
            for (&self.jobs) |*job| if (job.connection == item and job.phase != .free and job.phase != .finished and std.meta.activeTag(job.work) == .open) {
                opening = true;
            };
            if (opening) continue;
        }
        return item;
    };
    return null;
}

fn runnable(self: *Plugin) ?*Job {
    for (self.queue[0..self.queue_len]) |index| {
        const job = &self.jobs[index];
        switch (job.work) {
            .closeDatabase => continue,
            .open => return job,
            else => {
                const item = job.connection.?;
                if (item.busy) continue;
                // Its connection closed meanwhile.
                if (item.phase != .open) return job;
                return job;
            },
        }
    }
    return null;
}

/// Worker: runs the job and records its result or failure.
fn run(self: *Plugin, job: *Job) void {
    const item = job.connection.?;
    if (std.meta.activeTag(job.work) != .open) {
        self.mutex.lock();
        const open_now = item.phase == .open;
        self.mutex.unlock();
        if (!open_now) {
            job.failure = .of(.closed, "sqlite: database is closed", .{});
            return;
        }
    }
    item.native.begin();
    const arena = job.arena.allocator();
    switch (job.work) {
        .open => |work| {
            openDatabase(self, item, job.path.?, work.params) catch |err| {
                job.failure = failureOf(item, err);
            };
        },
        .execute => |work| {
            job.result = execute(item, arena, work.params.sql, work.params.params) catch |err| {
                job.failure = failureOf(item, err);
                return;
            };
        },
        .query => |work| {
            job.parts = query(self, item, arena, work.params.sql, work.params.params) catch |err| {
                job.failure = failureOf(item, err);
                return;
            };
        },
        .transaction => |work| {
            job.results = batch(item, arena, work.params.statements) catch |err| {
                job.failure = failureOf(item, err);
                return;
            };
        },
        .closeDatabase => {},
    }
}

const RunError = native.Error || error{ Limit, Closed };

fn failureOf(item: *Connection, err: RunError) Failure {
    return switch (err) {
        error.Sqlite => .of(.sqlite, "sqlite: {s}", .{item.native.failure.text()}),
        error.Invalid => .of(.invalid, "sqlite: {s}", .{item.native.failure.text()}),
        error.Denied => .of(.denied, "sqlite: {s}", .{item.native.failure.text()}),
        error.Canceled, error.Closed => .of(.closed, "sqlite: database is closed", .{}),
        error.Limit => .of(.limit, "sqlite: the result is too large", .{}),
        error.OutOfMemory => .of(.sqlite, "sqlite: out of memory", .{}),
    };
}

fn openDatabase(self: *Plugin, item: *Connection, path: [:0]const u8, params: Service.Open) RunError!void {
    if (!std.mem.eql(u8, path, ":memory:")) try prepareDirectory(self, item, params.name, params.readOnly);
    try item.native.open(path, params.readOnly);
}

/// Creates the directories of a writable database, and refuses a name that
/// goes through a symlink or is not a file.
fn prepareDirectory(self: *Plugin, item: *Connection, name: []const u8, read_only: bool) RunError!void {
    if (!read_only) std.fs.cwd().makePath(self.options.directory) catch {};
    var dir = std.fs.openDirAbsolute(self.options.directory, .{}) catch |err| switch (err) {
        // SQLite reports the missing database.
        error.FileNotFound => return,
        else => return denied(item, "the plugin's directory cannot be opened"),
    };
    defer dir.close();
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        const last = parts.peek() == null;
        const found = statAt(dir, part) catch |err| switch (err) {
            error.FileNotFound => {
                if (last) return;
                if (read_only) return;
                dir.makeDir(part) catch {};
                const next = dir.openDir(part, .{ .no_follow = true }) catch return denied(item, "a directory of the name cannot be opened");
                dir.close();
                dir = next;
                continue;
            },
            else => return denied(item, "the name cannot be looked at"),
        };
        if (last) {
            if (found != .file) return denied(item, "the database must be a regular file, not a symlink");
            return;
        }
        if (found != .directory) return denied(item, "the name goes through a symlink or a file");
        const next = dir.openDir(part, .{ .no_follow = true }) catch return denied(item, "a directory of the name cannot be opened");
        dir.close();
        dir = next;
    }
}

fn denied(item: *Connection, comptime message: []const u8) RunError {
    item.native.failure = .{};
    @memcpy(item.native.failure.message[0..message.len], message);
    item.native.failure.len = message.len;
    return error.Denied;
}

fn statAt(dir: std.fs.Dir, name: []const u8) !std.fs.File.Kind {
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
        return (try file.stat()).kind;
    }
    const linux = std.os.linux;
    const path = try std.posix.toPosixPath(name);
    var stx = std.mem.zeroes(linux.Statx);
    return switch (linux.E.init(linux.statx(dir.fd, &path, linux.AT.SYMLINK_NOFOLLOW, linux.STATX_TYPE, &stx))) {
        .SUCCESS => switch (stx.mode & linux.S.IFMT) {
            linux.S.IFREG => .file,
            linux.S.IFDIR => .directory,
            linux.S.IFLNK => .sym_link,
            else => .unknown,
        },
        .NOENT => error.FileNotFound,
        else => error.Unexpected,
    };
}

fn prepared(item: *Connection, arena: std.mem.Allocator, sql: []const u8, params: []const Service.Value) RunError!native.Statement {
    var statement = try item.native.prepare(sql);
    errdefer statement.deinit();
    const count = statement.parameterCount();
    if (count != params.len) {
        item.native.failure = .{};
        item.native.failure.len = (std.fmt.bufPrint(&item.native.failure.message, "statement needs {d} parameters, got {d}", .{ count, params.len }) catch "").len;
        return error.Invalid;
    }
    for (params, 1..) |param, index| {
        const value = bound(arena, param) catch |err| {
            item.native.failure = .{};
            item.native.failure.len = (std.fmt.bufPrint(&item.native.failure.message, "parameter {d}: {s}", .{ index, switch (err) {
                error.OutOfMemory => "out of memory",
                error.InvalidInteger => "invalid signed 64-bit integer",
                error.NotFinite => "number must be finite",
                error.InvalidBlob => "invalid BLOB encoding",
                error.InvalidValue => "the value does not match its type",
            } }) catch "").len;
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
        };
        try statement.bind(index, value);
    }
    return statement;
}

fn bound(arena: std.mem.Allocator, value: Service.Value) !native.Statement.Bound {
    return switch (value.type) {
        .null => .null,
        .integer => .{ .integer = std.fmt.parseInt(i64, value.integer orelse return error.InvalidValue, 10) catch return error.InvalidInteger },
        .real => {
            if (value.special != null) return error.NotFinite;
            const real = value.real orelse return error.InvalidValue;
            if (!std.math.isFinite(real)) return error.NotFinite;
            return .{ .real = real };
        },
        .text => .{ .text = value.text orelse return error.InvalidValue },
        .blob => {
            const text = value.blob orelse return error.InvalidValue;
            const decoder = std.base64.standard.Decoder;
            const bytes = try arena.alloc(u8, decoder.calcSizeForSlice(text) catch return error.InvalidBlob);
            decoder.decode(bytes, text) catch return error.InvalidBlob;
            return .{ .blob = bytes };
        },
    };
}

fn execute(item: *Connection, arena: std.mem.Allocator, sql: []const u8, params: []const Service.Value) RunError!Service.Result {
    var statement = try prepared(item, arena, sql, params);
    defer statement.deinit();
    const before = statement.totalChanges();
    // RETURNING rows are consumed.
    while (try statement.step()) {}
    const changes = statement.changes(before);
    return .{ .changes = @intCast(std.math.clamp(changes, std.math.minInt(i53), std.math.maxInt(i53))), .lastInsertId = try std.fmt.allocPrint(arena, "{d}", .{item.native.lastInsertId()}) };
}

fn query(self: *Plugin, item: *Connection, arena: std.mem.Allocator, sql: []const u8, params: []const Service.Value) RunError![]const Service.Rows {
    var statement = try prepared(item, arena, sql, params);
    defer statement.deinit();
    const columns = try arena.alloc([]const u8, statement.columnCount());
    var bytes: usize = 64;
    for (columns, 0..) |*name, index| {
        name.* = try sanitize(arena, statement.columnName(index));
        bytes += 8 + 6 * name.len;
    }
    var parts: std.ArrayList(Service.Rows) = .empty;
    var rows: std.ArrayList([]const Service.Value) = .empty;
    var part = bytes;
    var total: usize = 0;
    while (try statement.step()) {
        const cells = try arena.alloc(Service.Value, columns.len);
        var size: usize = 4;
        for (cells, 0..) |*cell, index| {
            cell.* = try wire(arena, statement.column(index));
            size += 48 + if (cell.text) |text| 6 * text.len else 0;
            size += if (cell.blob) |blob| blob.len else 0;
            size += if (cell.integer) |integer| integer.len else 0;
        }
        total += size;
        if (total > self.options.max_result_bytes) return error.Limit;
        if (rows.items.len > 0 and part + size > part_bytes) {
            try parts.append(arena, .{ .columns = if (parts.items.len == 0) columns else null, .rows = try rows.toOwnedSlice(arena) });
            part = 0;
        }
        try rows.append(arena, cells);
        part += size;
    }
    try parts.append(arena, .{ .columns = if (parts.items.len == 0) columns else null, .rows = try rows.toOwnedSlice(arena) });
    return parts.items;
}

fn batch(item: *Connection, arena: std.mem.Allocator, statements: []const Service.Item) RunError![]const Service.Result {
    if (statements.len == 0) return &.{};
    try item.native.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed and item.native.inTransaction()) {
        // Rolling back must run even after an interrupt.
        item.native.begin();
        item.native.exec("ROLLBACK") catch {};
    };
    const results = try arena.alloc(Service.Result, statements.len);
    for (statements, results, 1..) |statement, *result, index| {
        result.* = execute(item, arena, statement.sql, statement.params) catch |err| {
            if (err == error.Sqlite or err == error.Invalid or err == error.Denied) {
                var failure = item.native.failure;
                item.native.failure.len = (std.fmt.bufPrint(&item.native.failure.message, "statement {d}: {s}", .{ index, failure.text() }) catch "").len;
                _ = &failure;
            }
            return err;
        };
    }
    if (item.native.isCanceled()) return error.Canceled;
    try item.native.exec("COMMIT");
    committed = true;
    return results;
}

fn wire(arena: std.mem.Allocator, cell: native.Statement.Cell) !Service.Value {
    var value: Service.Value = .{ .type = .null, .integer = null, .real = null, .special = null, .text = null, .blob = null };
    switch (cell) {
        .null => {},
        .integer => |n| {
            value.type = .integer;
            value.integer = try std.fmt.allocPrint(arena, "{d}", .{n});
        },
        .real => |f| {
            value.type = .real;
            if (std.math.isNan(f)) {
                value.special = .NaN;
            } else if (std.math.isInf(f)) {
                value.special = if (f > 0) .Infinity else .@"-Infinity";
            } else value.real = f;
        },
        .text => |text| {
            value.type = .text;
            value.text = try sanitize(arena, text);
        },
        .blob => |bytes| {
            value.type = .blob;
            const encoder = std.base64.standard.Encoder;
            const encoded = try arena.alloc(u8, encoder.calcSize(bytes.len));
            value.blob = encoder.encode(encoded, bytes);
        },
    }
    return value;
}

/// A copy of `bytes` as UTF-8, invalid sequences replaced by U+FFFD.
fn sanitize(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return arena.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[at]) catch {
            try out.appendSlice(arena, "\u{FFFD}");
            at += 1;
            continue;
        };
        if (at + length <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[at .. at + length])) |_| {
                try out.appendSlice(arena, bytes[at .. at + length]);
                at += length;
                continue;
            } else |_| {}
        }
        try out.appendSlice(arena, "\u{FFFD}");
        at += 1;
    }
    return out.items;
}

/// A relative file name in the plugin's directory, or ":memory:".
fn validName(name: []const u8) bool {
    if (std.mem.eql(u8, name, ":memory:")) return true;
    if (name.len == 0 or name.len > 1024 or !std.unicode.utf8ValidateSlice(name)) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| if (byte < 32 or byte == '\\' or byte == ':' or byte == '*' or byte == '?' or byte == '"' or byte == '<' or byte == '>' or byte == '|') return false;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        if (device(part)) return false;
    }
    return true;
}

/// Windows device names, with any extension, name no file anywhere.
fn device(part: []const u8) bool {
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |name| if (std.ascii.eqlIgnoreCase(stem, name)) return true;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt")) and stem[3] >= '0' and stem[3] <= '9') return true;
    return false;
}

test "database names stay in the directory" {
    try std.testing.expect(validName("app.db"));
    try std.testing.expect(validName("data/app.db"));
    try std.testing.expect(validName(":memory:"));
    for ([_][]const u8{ "", "/etc/passwd", "../x.db", "a/../b", "a//b", "C:\\x", "c:x", "nul", "NUL.txt", "com1.db", "lpt9", "x.", "a\\b", "file:x.db" }) |name| {
        try std.testing.expect(!validName(name));
    }
}

test {
    _ = native;
    _ = @import("sqlite_test.zig");
}
