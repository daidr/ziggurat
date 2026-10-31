//! Fixtures for plugin tests: a Host connected to a recorded page, and a
//! queue that stands in for the main thread's mailbox.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const ipc = @import("ziggurat_ipc");
const host_api = @import("host.zig");
const controls_api = @import("controls.zig");
const outbox = @import("outbox.zig");

/// Posted tasks run when the test drains, on the test's thread.
pub const Queue = struct {
    mutex: zio.Mutex = .{},
    posted: zio.Condition = .{},
    tasks: [16]z.Task = undefined,
    len: usize = 0,
    full: bool = false,
    closed: bool = false,

    pub fn poster(self: *Queue) outbox.Post {
        return .{ .context = self, .post = post };
    }

    fn post(context: *anyopaque, task: z.Task) error{ Full, Closed }!void {
        const self: *Queue = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.full or self.len == self.tasks.len) return error.Full;
        self.tasks[self.len] = task;
        self.len += 1;
        self.posted.broadcast();
    }

    /// Runs one posted task, waiting at most `timeout_ms` for it.
    pub fn runOne(self: *Queue, timeout_ms: u64) !void {
        self.mutex.lock();
        while (self.len == 0) self.posted.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms) catch {
            self.mutex.unlock();
            return error.Timeout;
        };
        const task = self.tasks[0];
        std.mem.copyForwards(z.Task, self.tasks[0 .. self.len - 1], self.tasks[1..self.len]);
        self.len -= 1;
        self.mutex.unlock();
        task.call(task.context);
    }
};

/// A Host whose page records every packet; window controls do nothing.
pub const Page = struct {
    allocator: std.mem.Allocator,
    host: host_api.Host,
    packets: std.ArrayList([]u8) = .empty,
    /// Packets already looked at by `next`.
    seen: usize = 0,
    fail: bool = false,
    queue: Queue = .{},
    prng: std.Random.DefaultPrng = .init(7),

    /// The page stays at this address until `deinit`.
    pub fn init(self: *Page, allocator: std.mem.Allocator) void {
        self.* = .{ .allocator = allocator, .host = undefined };
        self.host = .init(allocator, .{
            .transport = .{ .context = self, .send = send },
            .controls = .{ .context = self, .vtable = &no_controls },
            .random = self.prng.random(),
        });
    }

    pub fn deinit(self: *Page) void {
        self.host.detach();
        for (self.packets.items) |packet| self.allocator.free(packet);
        self.packets.deinit(self.allocator);
    }

    /// A new document: hello, and its configuration.
    pub fn connect(self: *Page) !void {
        _ = self.host.receive(host_api.hello);
        if (!self.host.connected()) return error.NotConnected;
    }

    pub fn session(self: *Page, name: []const u8) ![32]u8 {
        var index = self.packets.items.len;
        while (index > 0) {
            index -= 1;
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, self.packets.items[index], .{});
            defer parsed.deinit();
            const tag = parsed.value.object.get("ziggurat") orelse continue;
            if (!std.mem.eql(u8, tag.string, "runtime")) continue;
            const text = (parsed.value.object.get("services").?.object.get(name) orelse return error.NoService).string;
            return text[0..32].*;
        }
        return error.NotConfigured;
    }

    /// Calls `method` of the plugin service `name` ("plugin:fetch").
    pub fn call(self: *Page, name: []const u8, slot: u16, id: u32, method: []const u8, params: anytype) !void {
        const s = try self.session(name);
        const bytes = try ipc.protocol.encode(self.allocator, .{ .v = 1, .session = &s, .kind = "call", .slot = slot, .id = id, .method = method, .params = params }, 64 * 1024 * 1024);
        defer self.allocator.free(bytes);
        _ = self.host.receive(bytes);
    }

    pub fn ack(self: *Page, name: []const u8, slot: u16, id: u32, sequence: u32) !void {
        const s = try self.session(name);
        const bytes = try ipc.protocol.encode(self.allocator, .{ .v = 1, .session = &s, .kind = "ack", .slot = slot, .id = id, .sequence = sequence }, 4096);
        defer self.allocator.free(bytes);
        _ = self.host.receive(bytes);
    }

    pub fn cancel(self: *Page, name: []const u8, slot: u16, id: u32) !void {
        const s = try self.session(name);
        const bytes = try ipc.protocol.encode(self.allocator, .{ .v = 1, .session = &s, .kind = "cancel", .slot = slot, .id = id }, 4096);
        defer self.allocator.free(bytes);
        _ = self.host.receive(bytes);
    }

    /// The next packet not yet looked at, parsed; runs posted tasks while
    /// there is none.
    pub fn next(self: *Page, timeout_ms: u64) !std.json.Parsed(std.json.Value) {
        while (self.seen == self.packets.items.len) try self.queue.runOne(timeout_ms);
        self.seen += 1;
        return std.json.parseFromSlice(std.json.Value, self.allocator, self.packets.items[self.seen - 1], .{});
    }

    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *Page = @ptrCast(@alignCast(context));
        if (self.fail) return error.TransportFailed;
        try self.packets.append(self.allocator, try self.allocator.dupe(u8, bytes));
    }

    fn nothing(_: *anyopaque) !void {}
    fn notMaximized(_: *anyopaque) !bool {
        return false;
    }
    fn noTitle(_: *anyopaque, _: []const u8) !void {}
    const no_controls: controls_api.Controls.VTable = .{
        .minimize = nothing,
        .maximize = nothing,
        .unmaximize = nothing,
        .toggleMaximize = nothing,
        .isMaximized = notMaximized,
        .toggleFullScreen = nothing,
        .close = nothing,
        .setTitle = noTitle,
    };
};
