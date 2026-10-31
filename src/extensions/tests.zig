const std = @import("std");
const ext = @import("root.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Log = struct {
    entries: [256]i16 = undefined,
    len: usize = 0,
    fn add(self: *Log, value: i16) void {
        self.entries[self.len] = value;
        self.len += 1;
    }
};
const Context = struct {
    log: *Log,
    id: i16,
    fail: bool = false,
    graph: ?*ext.Graph = null,
    cancel: bool = false,
    prerequisite: ?[]const u8 = null,
    resource: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,
    own_name: []const u8 = "",

    fn start(ptr: *anyopaque) !void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.log.add(self.id);
        if (self.graph) |graph| {
            try expectError(error.Busy, graph.start());
            try expectError(error.Busy, graph.stop());
            if (self.prerequisite) |name| try expect(try graph.isActive(name));
            if (self.cancel) try graph.requestStop();
        }
        if (self.fail) return error.StartFailure;
        if (self.allocator) |allocator| self.resource = try allocator.alloc(u8, 32);
    }
    fn stop(ptr: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.log.add(-self.id);
        if (self.graph) |graph| {
            expectError(error.Busy, graph.stop()) catch @panic("recursive stop");
            expectError(error.Busy, graph.start()) catch @panic("recursive start");
            expect(!(graph.isActive(self.own_name) catch @panic("owner"))) catch @panic("still active during stop");
            if (self.prerequisite) |name| expect(graph.isActive(name) catch @panic("owner")) catch @panic("prerequisite stopped first");
            graph.requestStop() catch @panic("owner");
        }
        if (self.resource) |resource| self.allocator.?.free(resource);
        self.resource = null;
    }
    fn plugin(self: *Context, name: []const u8, requires: []const []const u8) ext.Plugin {
        self.own_name = name;
        return .{ .name = name, .requires = requires, .context = self, .start = start, .stop = stop };
    }
};

test "dependency validation is transactional and bounded" {
    var log: Log = .{};
    var ctx: Context = .{ .log = &log, .id = 1 };
    try expectError(error.InvalidName, ext.Graph.init(&.{ctx.plugin("", &.{})}));
    try expectError(error.InvalidName, ext.Graph.init(&.{ctx.plugin("A", &.{})}));
    try expectError(error.InvalidName, ext.Graph.init(&.{ctx.plugin("9bad", &.{})}));
    try expectError(error.InvalidName, ext.Graph.init(&.{ctx.plugin("a_b", &.{})}));
    try expectError(error.InvalidName, ext.Graph.init(&.{ctx.plugin(&@as([ext.max_name_bytes + 1]u8, @splat('a')), &.{})}));
    try expectError(error.DuplicatePlugin, ext.Graph.init(&.{ ctx.plugin("a", &.{}), ctx.plugin("a", &.{}) }));
    try expectError(error.MissingDependency, ext.Graph.init(&.{ctx.plugin("a", &.{"absent"})}));
    try expectError(error.DuplicateDependency, ext.Graph.init(&.{ ctx.plugin("a", &.{}), ctx.plugin("b", &.{ "a", "a" }) }));
    try expectError(error.CyclicDependency, ext.Graph.init(&.{ctx.plugin("a", &.{"a"})}));
    try expectError(error.CyclicDependency, ext.Graph.init(&.{ ctx.plugin("a", &.{"b"}), ctx.plugin("b", &.{"a"}) }));
    var over: [ext.max_plugins + 1]ext.Plugin = @splat(ctx.plugin("a", &.{}));
    try expectError(error.CapacityExceeded, ext.Graph.init(&over));
    try expectError(error.CapacityExceeded, ext.Graph.init(&.{ctx.plugin("a", &(@as([ext.max_plugins + 1][]const u8, @splat("a"))))}));
    try equal(@as(usize, 0), log.len);
}

test "topological start and reverse stop preserve live prerequisites under callback reentry" {
    var log: Log = .{};
    var a: Context = .{ .log = &log, .id = 1 };
    var b: Context = .{ .log = &log, .id = 2, .prerequisite = "a" };
    var c: Context = .{ .log = &log, .id = 3, .prerequisite = "b" };
    var graph = try ext.Graph.init(&.{ c.plugin("c", &.{ "a", "b" }), b.plugin("b", &.{"a"}), a.plugin("a", &.{}) });
    a.graph = &graph;
    b.graph = &graph;
    c.graph = &graph;
    try expect(!(try graph.isActive("a")));
    try expect(!(try graph.isActive("missing")));
    try graph.start();
    try equal(ext.State.running, graph.state);
    try expect(try graph.isActive("c"));
    try expectError(error.AlreadyStarted, graph.start());
    try graph.stop();
    try graph.stop();
    try expectError(error.Stopped, graph.start());
    try equal(ext.State.stopped, graph.state);
    try equal(@as(u64, 0), graph.active_mask);
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, 3, -3, -2, -1 }, log.entries[0..log.len]);
}

test "initializer failure rolls back once and retains the original error" {
    var log: Log = .{};
    var a: Context = .{ .log = &log, .id = 1 };
    var b: Context = .{ .log = &log, .id = 2, .fail = true };
    var c: Context = .{ .log = &log, .id = 3 };
    var graph = try ext.Graph.init(&.{ a.plugin("a", &.{}), b.plugin("b", &.{"a"}), c.plugin("c", &.{"b"}) });
    try expectError(error.StartFailure, graph.start());
    try equal(ext.State.failed, graph.state);
    try equal(@as(usize, 1), graph.failure.?.index);
    try std.testing.expectEqualStrings("b", try graph.pluginName(graph.failure.?.index));
    try equal(error.StartFailure, graph.failure.?.err);
    try equal(@as(usize, 0), graph.started);
    try equal(@as(u64, 0), graph.active_mask);
    try graph.stop();
    try expectError(error.Stopped, graph.start());
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, -1 }, log.entries[0..log.len]);
}

test "cancellation waits for the current callback and prevents later initialization" {
    var log: Log = .{};
    var a: Context = .{ .log = &log, .id = 1, .cancel = true };
    var b: Context = .{ .log = &log, .id = 2 };
    var graph = try ext.Graph.init(&.{ a.plugin("a", &.{}), b.plugin("b", &.{"a"}) });
    a.graph = &graph;
    try expectError(error.StartCancelled, graph.start());
    try equal(ext.State.stopped, graph.state);
    try expect(graph.failure == null);
    try std.testing.expectEqualSlices(i16, &.{ 1, -1 }, log.entries[0..log.len]);
    var empty = try ext.Graph.init(&.{});
    try empty.requestStop();
    try expectError(error.StartCancelled, empty.start());
    try equal(ext.State.stopped, empty.state);
    log.len = 0;
    graph = try ext.Graph.init(&.{a.plugin("a", &.{})});
    try graph.requestStop();
    try expectError(error.StartCancelled, graph.start());
    try equal(@as(usize, 0), log.len);
}

test "descriptors and edges are snapshots and running stop request is explicit intent" {
    var log: Log = .{};
    var a: Context = .{ .log = &log, .id = 1 };
    var b: Context = .{ .log = &log, .id = 2 };
    var deps = [_][]const u8{"a"};
    var name = [_]u8{'b'};
    var plugins = [_]ext.Plugin{ b.plugin(&name, &deps), a.plugin("a", &.{}) };
    var graph = try ext.Graph.init(&plugins);
    name[0] = 'x';
    deps[0] = "missing";
    plugins[0].requires = &.{};
    plugins[0].start = undefined;
    try graph.start();
    try graph.requestStop();
    try equal(ext.State.running, graph.state);
    try expect(try graph.isActive("b"));
    try graph.stop();
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, -2, -1 }, log.entries[0..log.len]);
    try std.testing.expectEqualStrings("b", try graph.pluginName(0));
    try expectError(error.InvalidPluginIndex, graph.pluginName(2));
}

test "graph validates thread ownership before mutation or callbacks" {
    var graph = try ext.Graph.init(&.{});
    const Worker = struct {
        fn run(g: *ext.Graph) void {
            expectError(error.WrongThread, g.start()) catch @panic("cross-thread start");
            expectError(error.WrongThread, g.stop()) catch @panic("cross-thread stop");
            expectError(error.WrongThread, g.requestStop()) catch @panic("cross-thread request");
            expectError(error.WrongThread, g.isActive("a")) catch @panic("cross-thread query");
            expectError(error.WrongThread, g.pluginName(0)) catch @panic("cross-thread name");
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&graph});
    worker.join();
    try equal(ext.State.ready, graph.state);
    try expect(!graph.stop_requested);
    try graph.start();
    try graph.stop();
}

fn allocating(allocator: std.mem.Allocator) !void {
    var log: Log = .{};
    var a: Context = .{ .log = &log, .id = 1, .allocator = allocator };
    var b: Context = .{ .log = &log, .id = 2, .allocator = allocator };
    var graph = try ext.Graph.init(&.{ a.plugin("a", &.{}), b.plugin("b", &.{"a"}) });
    defer graph.stop() catch unreachable;
    graph.start() catch |err| {
        try equal(@as(u64, 0), graph.active_mask);
        try expect(a.resource == null and b.resource == null);
        return err;
    };
    try expect(a.resource != null and b.resource != null);
}
test "allocation failures inside plugins release all successful prerequisites" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocating, .{});
}

test "maximum graph supports bit 63 and stable declaration order with zero heap" {
    var log: Log = .{};
    var contexts: [ext.max_plugins]Context = undefined;
    var plugins: [ext.max_plugins]ext.Plugin = undefined;
    var names: [ext.max_plugins][8]u8 = undefined;
    for (&contexts, &plugins, &names, 0..) |*ctx, *plugin, *name, i| {
        ctx.* = .{ .log = &log, .id = @intCast(i + 1) };
        plugin.* = ctx.plugin(try std.fmt.bufPrint(name, "p{d}", .{i}), &.{});
    }
    plugins[0].requires = &.{plugins[63].name};
    var graph = try ext.Graph.init(&plugins);
    try graph.start();
    try equal(std.math.maxInt(u64), graph.active_mask);
    try expect(try graph.isActive(plugins[63].name));
    try graph.stop();
    try equal(@as(i16, 2), log.entries[0]);
    try equal(@as(i16, 64), log.entries[62]);
    try equal(@as(i16, 1), log.entries[63]);
    try equal(@as(i16, -1), log.entries[64]);
    try equal(@as(i16, -2), log.entries[127]);
}
