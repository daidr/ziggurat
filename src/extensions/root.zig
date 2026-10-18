const std = @import("std");

pub const max_plugins = 64;
pub const max_name_bytes = 64;

/// Strings and descriptors are borrowed only by Graph.init. Contexts remain
/// valid until Graph.stop completes; callbacks run on the init thread.
pub const Plugin = struct {
    name: []const u8,
    requires: []const []const u8 = &.{},
    context: *anyopaque,
    /// A failing initializer must release its own partially acquired resources.
    /// Successful initializers are stopped in reverse dependency order.
    start: *const fn (*anyopaque) anyerror!void,
    stop: *const fn (*anyopaque) void,
};

pub const State = enum { ready, starting, running, stopping, stopped, failed };
pub const Failure = struct { index: usize, err: anyerror };
const Entry = struct {
    name: [max_name_bytes]u8 = undefined,
    name_len: u8,
    context: *anyopaque,
    start: *const fn (*anyopaque) anyerror!void,
    stop: *const fn (*anyopaque) void,
};

/// An explicit, single-use dependency graph. No heap allocation, global
/// registry, native dependency, worker, service binding or event loop is added.
/// Once start is called, do not copy or move this owning value until terminal
/// shutdown returns. All operations use its owner thread.
pub const Graph = struct {
    owner: std.Thread.Id,
    entries: [max_plugins]Entry = undefined,
    order: [max_plugins]u8 = undefined,
    count: usize = 0,
    started: usize = 0,
    active_mask: u64 = 0,
    state: State = .ready,
    failure: ?Failure = null,
    stop_requested: bool = false,

    /// Validate the entire graph before any callback. Ready peers preserve
    /// declaration order; prerequisites always start before their dependants.
    pub fn init(plugins: []const Plugin) !Graph {
        if (plugins.len > max_plugins) return error.CapacityExceeded;
        var graph: Graph = .{ .owner = std.Thread.getCurrentId(), .count = plugins.len };
        var edges: [max_plugins]u64 = @splat(0);
        for (plugins, 0..) |plugin, i| {
            if (!validName(plugin.name)) return error.InvalidName;
            for (plugins[0..i]) |previous| if (std.mem.eql(u8, previous.name, plugin.name)) return error.DuplicatePlugin;
            graph.entries[i] = .{ .name_len = @intCast(plugin.name.len), .context = plugin.context, .start = plugin.start, .stop = plugin.stop };
            @memcpy(graph.entries[i].name[0..plugin.name.len], plugin.name);
        }
        for (plugins, 0..) |plugin, i| {
            if (plugin.requires.len > max_plugins) return error.CapacityExceeded;
            for (plugin.requires) |name| {
                const index = graph.find(name) orelse return error.MissingDependency;
                const bit = @as(u64, 1) << @intCast(index);
                if (edges[i] & bit != 0) return error.DuplicateDependency;
                edges[i] |= bit;
            }
        }
        var scheduled: u64 = 0;
        for (graph.order[0..plugins.len]) |*slot| {
            var selected: ?usize = null;
            for (0..plugins.len) |i| {
                const bit = @as(u64, 1) << @intCast(i);
                if (scheduled & bit == 0 and edges[i] & ~scheduled == 0) {
                    selected = i;
                    break;
                }
            }
            const index = selected orelse return error.CyclicDependency;
            slot.* = @intCast(index);
            scheduled |= @as(u64, 1) << @intCast(index);
        }
        return graph;
    }

    pub fn start(self: *Graph) !void {
        try self.requireOwner();
        switch (self.state) {
            .starting, .stopping => return error.Busy,
            .running => return error.AlreadyStarted,
            .stopped, .failed => return error.Stopped,
            .ready => {},
        }
        self.state = .starting;
        if (self.stop_requested) {
            self.state = .stopped;
            return error.StartCancelled;
        }
        for (self.order[0..self.count]) |index| {
            const entry = self.entries[index];
            entry.start(entry.context) catch |err| {
                self.failure = .{ .index = index, .err = err };
                self.unwind(.failed);
                return err;
            };
            self.active_mask |= @as(u64, 1) << @intCast(index);
            self.started += 1;
            if (self.stop_requested) {
                self.unwind(.stopped);
                return error.StartCancelled;
            }
        }
        self.state = .running;
    }

    /// During start this requests rollback after the current initializer
    /// returns. During running it marks intent; the host calls stop at its safe
    /// point after cancelling/joining asynchronous plugin work.
    pub fn requestStop(self: *Graph) !void {
        try self.requireOwner();
        self.stop_requested = true;
    }

    /// Idempotent after shutdown. Reentry from a start/stop callback is Busy;
    /// no callback can recursively tear down a prerequisite still in use.
    pub fn stop(self: *Graph) !void {
        try self.requireOwner();
        switch (self.state) {
            .starting, .stopping => return error.Busy,
            .stopped, .failed => return,
            .ready, .running => self.unwind(.stopped),
        }
    }

    /// Only successfully initialized, not-yet-stopped plugins are active.
    /// During stop a plugin becomes inactive immediately before its callback.
    pub fn isActive(self: *const Graph, name: []const u8) !bool {
        try self.requireOwner();
        const index = self.find(name) orelse return false;
        return self.active_mask & (@as(u64, 1) << @intCast(index)) != 0;
    }

    /// Borrowed from this Graph, including after stop. Useful with Failure.index
    /// after the caller has released the original descriptors and name strings.
    pub fn pluginName(self: *const Graph, index: usize) ![]const u8 {
        try self.requireOwner();
        if (index >= self.count) return error.InvalidPluginIndex;
        const entry = &self.entries[index];
        return entry.name[0..entry.name_len];
    }

    fn requireOwner(self: *const Graph) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn find(self: *const Graph, name: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*entry, i| if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return i;
        return null;
    }
    fn unwind(self: *Graph, final_state: State) void {
        self.state = .stopping;
        while (self.started != 0) {
            self.started -= 1;
            const index = self.order[self.started];
            const entry = self.entries[index];
            self.active_mask &= ~(@as(u64, 1) << @intCast(index));
            entry.stop(entry.context);
        }
        self.state = final_state;
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    return true;
}

test {
    _ = @import("tests.zig");
}
