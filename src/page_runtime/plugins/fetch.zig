//! Fetch plugin: pages make HTTP requests from the host through
//! `@ziggurat/plugin-fetch`, free of CORS and of the WebView's header rules.
//! The plugin starts its own workers, each making one request at a time with
//! `ziggurat_net`; heads and body chunks reach the main thread through
//! `App.post` and stream to the page as they arrive.
const std = @import("std");
const ipc = @import("ziggurat_ipc");
const net = @import("ziggurat_net");
const runtime = @import("ziggurat_page_runtime");

pub const Service = @import("fetch_service.zig").Service;
const limits = Service.limits;
const Dispatcher = ipc.Dispatcher(Service, Implementation, Plugin, limits);
const Work = ipc.Work(Service, limits, "fetch");

/// Body bytes in one chunk sent to the page; its Base64 fits in a message.
pub const chunk_bytes = 32 * 1024;
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;

/// What `Allow` sees of a request before it is made.
pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const net.Header,
};

/// Decides on the main thread whether pages may make a request. It sees the
/// first request only; redirects follow `Options.limits.redirects`.
pub const Allow = struct {
    context: *anyopaque,
    allow: *const fn (*anyopaque, Request) bool,
};

pub const Options = struct {
    post: runtime.Post,
    /// Workers the plugin starts in `init` and joins in `deinit`. Requests
    /// beyond them wait in order.
    workers: u8 = 4,
    allow: ?Allow = null,
    /// Redirects follow up to 20 hops, as browsers do; bodies are unbounded.
    limits: net.Limits = .{ .response_bytes = std.math.maxInt(usize) / 2, .redirects = 20 },
    /// Request body bytes a page may have uploaded and not yet sent.
    max_upload_bytes: usize = 64 * 1024 * 1024,
};

/// A request body arriving in pieces; main thread.
const Upload = struct {
    used: bool = false,
    id: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,
};

/// Headers the transport owns; a page's values are dropped.
const transport_headers = [_][]const u8{ "content-length", "transfer-encoding", "connection", "keep-alive", "upgrade", "te", "trailer", "proxy-connection" };

const Job = struct {
    // Main thread.
    live: bool = false,
    work: Work = undefined,
    sent: u32 = 0,
    head_sent: bool = false,
    // Written by the main thread before the job is queued; read by its worker.
    request: net.Request = undefined,
    headers: []net.Header = &.{},
    /// The URL and header text, copied: the call's own storage is freed
    /// when the page stops waiting, while the worker may still read them.
    text: []u8 = &.{},
    body: ?[]u8 = null,
    cancel: net.Cancel = .{},
    buffers: [2][]u8 = .{ &.{}, &.{} },
    // Under the plugin mutex.
    phase: enum { free, queued, running, finished } = .free,
    abandoned: bool = false,
    changed: bool = false,
    head: ?net.Head = null,
    full: [2]bool = .{ false, false },
    lengths: [2]usize = .{ 0, 0 },
    filled: u32 = 0,
    result: net.FetchError!void = {},
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    options: Options,
    dispatcher: Dispatcher = .init(unset),
    implementation: Implementation = .{},
    host: ?*runtime.Host = null,
    jobs: [limits.max_pending]Job = @splat(.{}),
    threads: []std.Thread = &.{},
    mutex: std.Thread.Mutex = .{},
    queued: std.Thread.Condition = .{},
    returned: std.Thread.Condition = .{},
    queue: [limits.max_pending]u16 = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    stopping: bool = false,
    uploads: [limits.max_pending]Upload = @splat(.{}),
    upload_bytes: usize = 0,
    outbox: runtime.Outbox,
    /// Base64 of one chunk; main thread.
    encoded: []u8 = &.{},

    /// Starts the workers. The plugin stays at this address until `deinit`.
    /// `allocator` must be thread-safe: workers allocate with it.
    pub fn init(self: *Plugin, allocator: std.mem.Allocator, options: Options) !void {
        std.debug.assert(options.workers > 0);
        self.* = .{ .allocator = allocator, .options = options, .outbox = .{ .post = options.post, .drain = .{ .context = self, .call = drain } } };
        self.encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(chunk_bytes));
        errdefer allocator.free(self.encoded);
        self.threads = try allocator.alloc(std.Thread, options.workers);
        var started: usize = 0;
        errdefer {
            self.stop();
            for (self.threads[0..started]) |thread| thread.join();
            allocator.free(self.threads);
        }
        while (started < self.threads.len) : (started += 1) self.threads[started] = try std.Thread.spawn(.{}, worker, .{self});
    }

    /// Main thread, after `App.run` returned and before `App.deinit`, with the
    /// Host detached: cancels requests and joins the workers.
    pub fn deinit(self: *Plugin) void {
        self.stop();
        for (self.threads) |thread| thread.join();
        for (&self.jobs) |*job| {
            if (job.live) job.work.deinit();
            job.live = false;
            if (job.phase != .free) self.release(job);
        }
        self.dropUploads();
        self.allocator.free(self.threads);
        self.allocator.free(self.encoded);
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
        for (&self.jobs) |*job| if (job.phase == .queued or job.phase == .running) {
            job.abandoned = true;
            job.cancel.cancel();
        };
        self.queued.broadcast();
        self.returned.broadcast();
    }

    fn open(context: *anyopaque, host: *runtime.Host, session: ipc.Session) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.reset(session, &canceled) catch {};
        self.abandonAll();
        self.dropUploads();
        self.host = host;
    }

    fn close(context: *anyopaque, _: *runtime.Host) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.close(&canceled) catch unreachable;
        self.abandonAll();
        self.dropUploads();
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
        for (&self.jobs) |*job| if (job.live and sameToken(job.work.token, token)) return job;
        return null;
    }

    fn abandonAll(self: *Plugin) void {
        for (&self.jobs) |*job| if (job.live) self.abandon(job);
    }

    /// The page no longer waits: stop the worker and forget the call. The
    /// job is released once its worker lets go of it.
    fn abandon(self: *Plugin, job: *Job) void {
        job.live = false;
        job.work.deinit();
        job.cancel.cancel();
        self.mutex.lock();
        job.abandoned = true;
        const finished = job.phase == .finished;
        self.returned.broadcast();
        self.mutex.unlock();
        if (finished) self.release(job);
    }

    fn release(self: *Plugin, job: *Job) void {
        std.debug.assert(!job.live);
        if (job.head) |*head| head.deinit(self.allocator);
        for (job.buffers) |buffer| self.allocator.free(buffer);
        self.allocator.free(job.headers);
        self.allocator.free(job.text);
        if (job.body) |body| self.allocator.free(body);
        job.* = .{};
    }

    fn send(self: *Plugin, packet: []u8) bool {
        defer self.allocator.free(packet);
        const host = self.host orelse return false;
        // A failed send closes this endpoint before it returns.
        host.send(packet) catch return false;
        return true;
    }

    fn fail(self: *Plugin, token: ipc.Token, code: Service.Code, message: []const u8) void {
        const packet = self.dispatcher.router.fail("fetch", self.allocator, token, code, message) catch return;
        _ = self.send(packet);
    }

    /// Main thread: starts a validated request on a free job.
    fn start(self: *Plugin, work: Work) void {
        var owned = work;
        const token = owned.token;
        const params = owned.params;
        const job = for (&self.jobs) |*job| {
            if (job.phase == .free) break job;
        } else {
            owned.deinit();
            return self.fail(token, .busy, "Too many requests");
        };
        const method = std.meta.stringToEnum(std.http.Method, params.method) orelse {
            owned.deinit();
            return self.fail(token, .invalid, "Unsupported method");
        };
        const uri = std.Uri.parse(params.url) catch {
            owned.deinit();
            return self.fail(token, .invalid, "Invalid URL");
        };
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
            owned.deinit();
            return self.fail(token, .invalid, "Unsupported URL scheme");
        }
        if ((params.body != null or params.upload != null) and !method.requestHasBody()) {
            owned.deinit();
            return self.fail(token, .invalid, "This method cannot have a body");
        }
        if (params.body != null and params.upload != null) {
            owned.deinit();
            return self.fail(token, .invalid, "A request has one body");
        }
        if (params.upload) |id| {
            job.body = self.takeUpload(id) orelse {
                owned.deinit();
                return self.fail(token, .invalid, "Unknown upload");
            };
        }
        self.prepare(job, method, params) catch |err| {
            self.release(job);
            owned.deinit();
            return self.fail(token, .invalid, switch (err) {
                error.InvalidHeader => "Invalid header",
                error.InvalidBody => "Invalid body encoding",
                error.OutOfMemory => "Out of memory",
            });
        };
        if (self.options.allow) |allow| if (!allow.allow(allow.context, .{ .method = method, .url = job.request.url, .headers = job.headers })) {
            self.release(job);
            owned.deinit();
            return self.fail(token, .denied, "The app does not allow this request");
        };
        job.work = owned;
        job.live = true;
        self.mutex.lock();
        defer self.mutex.unlock();
        job.phase = .queued;
        self.queue[(self.queue_head + self.queue_len) % self.queue.len] = @intCast(job - &self.jobs[0]);
        self.queue_len += 1;
        self.queued.signal();
    }

    /// Main thread: appends a piece to the page's upload `id`.
    fn append(self: *Plugin, piece: Service.Piece) ipc.Reply(Service, "upload") {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(piece.data) catch return .{ .failure = .{ .code = .invalid, .message = "Invalid body encoding" } };
        const upload = for (&self.uploads) |*upload| {
            if (upload.used and upload.id == piece.upload) break upload;
        } else for (&self.uploads) |*upload| {
            if (!upload.used) {
                upload.* = .{ .used = true, .id = piece.upload };
                break upload;
            }
        } else return .{ .failure = .{ .code = .busy, .message = "Too many uploads" } };
        if (size > self.options.max_upload_bytes - self.upload_bytes) {
            self.dropUpload(upload);
            return .{ .failure = .{ .code = .invalid, .message = "Body too large" } };
        }
        const start_len = upload.bytes.items.len;
        upload.bytes.resize(self.allocator, start_len + size) catch {
            self.dropUpload(upload);
            return .{ .failure = .{ .code = .failed, .message = "Out of memory" } };
        };
        self.upload_bytes += size;
        decoder.decode(upload.bytes.items[start_len..], piece.data) catch {
            self.dropUpload(upload);
            return .{ .failure = .{ .code = .invalid, .message = "Invalid body encoding" } };
        };
        return .{ .result = {} };
    }

    fn takeUpload(self: *Plugin, id: u32) ?[]u8 {
        for (&self.uploads) |*upload| if (upload.used and upload.id == id) {
            self.upload_bytes -= upload.bytes.items.len;
            const bytes = upload.bytes.toOwnedSlice(self.allocator) catch {
                self.dropUpload(upload);
                return null;
            };
            upload.* = .{};
            return bytes;
        };
        return null;
    }

    fn dropUpload(self: *Plugin, upload: *Upload) void {
        self.upload_bytes -= upload.bytes.items.len;
        upload.bytes.deinit(self.allocator);
        upload.* = .{};
    }

    fn dropUploads(self: *Plugin) void {
        for (&self.uploads) |*upload| if (upload.used) self.dropUpload(upload);
    }

    fn prepare(self: *Plugin, job: *Job, method: std.http.Method, params: Service.Request) !void {
        var count: usize = 0;
        var bytes: usize = params.url.len;
        for (params.headers) |header| {
            if (!validHeader(header)) return error.InvalidHeader;
            if (transportHeader(header.name)) continue;
            count += 1;
            bytes += header.name.len + header.value.len;
        }
        job.headers = try self.allocator.alloc(net.Header, count);
        job.text = try self.allocator.alloc(u8, bytes);
        var copied: usize = 0;
        const url = copy(job.text, &copied, params.url);
        count = 0;
        for (params.headers) |header| if (!transportHeader(header.name)) {
            job.headers[count] = .{ .name = copy(job.text, &copied, header.name), .value = copy(job.text, &copied, header.value) };
            count += 1;
        };
        if (params.body) |text| {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(text) catch return error.InvalidBody;
            const body = try self.allocator.alloc(u8, size);
            job.body = body;
            decoder.decode(body, text) catch return error.InvalidBody;
        }
        for (&job.buffers) |*buffer| buffer.* = try self.allocator.alloc(u8, chunk_bytes);
        job.request = .{
            .method = method,
            .url = url,
            .headers = job.headers,
            .body = job.body,
            .redirect = switch (params.redirect) {
                .follow => .follow,
                .manual => .manual,
                .@"error" => .reject,
            },
        };
    }

    /// Main thread, in the posted drain: hands what workers produced to the
    /// pages.
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
    }

    fn reap(self: *Plugin, job: *Job) void {
        self.mutex.lock();
        const finished = job.phase == .finished;
        self.mutex.unlock();
        if (finished) self.release(job);
    }

    /// Main thread: sends the head and filled buffers in order while the
    /// page has credit, then the result once the body is through.
    fn deliver(self: *Plugin, job: *Job) void {
        const token = job.work.token;
        if (!job.head_sent) {
            self.mutex.lock();
            const taken = job.head;
            job.head = null;
            self.mutex.unlock();
            if (taken) |value| {
                var head = value;
                defer head.deinit(self.allocator);
                job.head_sent = true;
                if (!self.sendHead(job, &head)) return;
            }
        }
        while (job.live) {
            const index = job.sent % 2;
            self.mutex.lock();
            const full = job.full[index];
            const length = job.lengths[index];
            self.mutex.unlock();
            if (!full) break;
            const text = std.base64.standard.Encoder.encode(self.encoded, job.buffers[index][0..length]);
            const packet = self.dispatcher.router.chunk("fetch", self.allocator, token, .{ .head = null, .chunk = text }) catch |err| switch (err) {
                // The page has not read enough yet; its acknowledgement resumes.
                error.Backpressure => return,
                else => return self.abandonWith(job, .failed, "Could not encode the body"),
            };
            job.sent += 1;
            self.mutex.lock();
            job.full[index] = false;
            self.returned.broadcast();
            self.mutex.unlock();
            if (!self.send(packet)) return;
        }
        if (!job.live) return;
        self.mutex.lock();
        const finished = job.phase == .finished and !job.full[0] and !job.full[1];
        const result = job.result;
        self.mutex.unlock();
        if (!finished) return;
        job.live = false;
        job.work.deinit();
        if (result) |_| {
            if (job.head_sent) {
                if (self.dispatcher.router.complete("fetch", self.allocator, token, {})) |packet| {
                    _ = self.send(packet);
                } else |_| {}
            } else self.fail(token, .failed, "No response");
        } else |err| self.fail(token, .failed, @errorName(err));
        self.release(job);
    }

    fn abandonWith(self: *Plugin, job: *Job, code: Service.Code, message: []const u8) void {
        const token = job.work.token;
        self.abandon(job);
        self.fail(token, code, message);
    }

    fn sendHead(self: *Plugin, job: *Job, head: *const net.Head) bool {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const wire = wireHead(arena.allocator(), head) catch {
            self.abandonWith(job, .failed, "Out of memory");
            return false;
        };
        const packet = self.dispatcher.router.chunk("fetch", self.allocator, job.work.token, .{ .head = wire, .chunk = null }) catch |err| {
            self.abandonWith(job, .failed, switch (err) {
                error.MessageTooLarge => "Response headers too large",
                error.InvalidUtf8 => "Response headers are not UTF-8",
                else => "Could not encode the response head",
            });
            return false;
        };
        return self.send(packet);
    }

    // Workers.

    fn worker(self: *Plugin) void {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();
        while (true) {
            self.mutex.lock();
            while (!self.stopping and self.queue_len == 0) self.queued.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const job = &self.jobs[self.queue[self.queue_head]];
            self.queue_head = (self.queue_head + 1) % self.queue.len;
            self.queue_len -= 1;
            job.phase = .running;
            const abandoned = job.abandoned;
            self.mutex.unlock();
            const result = if (abandoned) error.Cancelled else self.fetch(&client, job);
            self.mutex.lock();
            job.result = result;
            job.phase = .finished;
            job.changed = true;
            self.mutex.unlock();
            self.outbox.notify();
        }
    }

    fn fetch(self: *Plugin, client: *std.http.Client, job: *Job) net.FetchError!void {
        var sink: Sink = .{ .plugin = self, .job = job, .writer = .{ .vtable = &Sink.vtable, .buffer = job.buffers[0] } };
        try net.receive(self.allocator, client, job.request, self.options.limits, &job.cancel, .{ .context = &sink, .head = Sink.head, .body = &sink.writer });
        sink.writer.flush() catch return error.Cancelled;
    }

    /// Worker: marks the job changed and wakes the main thread.
    fn changed(self: *Plugin, job: *Job) void {
        job.changed = true;
        self.mutex.unlock();
        self.outbox.notify();
    }
};

/// The worker's end of a response body: fills the job's two buffers in turn
/// and waits for the main thread to return one when both are with it.
const Sink = struct {
    plugin: *Plugin,
    job: *Job,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drainBody };

    fn head(context: *anyopaque, value: net.Head) net.FetchError!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        var owned = value;
        const plugin = self.plugin;
        plugin.mutex.lock();
        if (self.job.abandoned) {
            plugin.mutex.unlock();
            owned.deinit(plugin.allocator);
            return error.Cancelled;
        }
        self.job.head = owned;
        plugin.changed(self.job);
    }

    fn drainBody(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @fieldParentPtr("writer", w);
        if (w.end > 0) try self.handOff();
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const n = put(w, bytes);
            written += n;
            if (n < bytes.len) return written;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            const n = put(w, last);
            written += n;
            if (n < last.len) return written;
        }
        return written;
    }

    fn put(w: *std.Io.Writer, bytes: []const u8) usize {
        const n = @min(bytes.len, w.buffer.len - w.end);
        @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
        w.end += n;
        return n;
    }

    fn handOff(self: *Sink) std.Io.Writer.Error!void {
        const plugin = self.plugin;
        const job = self.job;
        plugin.mutex.lock();
        const index = job.filled % 2;
        job.lengths[index] = self.writer.end;
        job.full[index] = true;
        job.filled += 1;
        plugin.changed(job);
        const next = job.filled % 2;
        plugin.mutex.lock();
        defer plugin.mutex.unlock();
        while (job.full[next] and !job.abandoned) plugin.returned.wait(&plugin.mutex);
        if (job.abandoned) return error.WriteFailed;
        self.writer.buffer = job.buffers[next];
        self.writer.end = 0;
    }
};

const Implementation = struct {
    pub fn fetch(_: *Implementation, plugin: *Plugin, work: Work) void {
        plugin.start(work);
    }
    pub fn upload(_: *Implementation, plugin: *Plugin, piece: Service.Piece) ipc.Reply(Service, "upload") {
        return plugin.append(piece);
    }
};

fn copy(storage: []u8, offset: *usize, text: []const u8) []const u8 {
    const target = storage[offset.*..][0..text.len];
    @memcpy(target, text);
    offset.* += text.len;
    return target;
}

fn sameToken(a: ipc.Token, b: ipc.Token) bool {
    return a.session.eql(b.session) and a.slot == b.slot and a.id == b.id;
}

fn transportHeader(name: []const u8) bool {
    for (transport_headers) |item| if (std.ascii.eqlIgnoreCase(item, name)) return true;
    return false;
}

fn validHeader(header: Service.Header) bool {
    if (header.name.len == 0) return false;
    for (header.name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    for (header.value) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

fn wireHead(arena: std.mem.Allocator, head: *const net.Head) !Service.Head {
    var count: usize = 0;
    for (head.headers) |header| if (!cookie(header.name)) {
        count += 1;
    };
    const headers = try arena.alloc(Service.Header, count);
    count = 0;
    for (head.headers) |header| if (!cookie(header.name)) {
        headers[count] = .{ .name = try std.ascii.allocLowerString(arena, header.name), .value = header.value };
        count += 1;
    };
    return .{ .status = @intFromEnum(head.status), .statusText = head.reason, .url = head.url, .redirected = head.redirects > 0, .headers = headers };
}

/// A page's Response cannot hold Set-Cookie.
fn cookie(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "set-cookie") or std.ascii.eqlIgnoreCase(name, "set-cookie2");
}

test {
    _ = @import("fetch_test.zig");
}
