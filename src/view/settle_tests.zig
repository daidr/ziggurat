//! Tests of `Host.settle`: in a window out of sight, which paints no frame
//! until it shows, the frame that waits to build there builds at once, so
//! that a press reaches the view and its nodes are what the window shows
//! now.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("root.zig");

const testing = std.testing;

const Counter = struct {
    count: u32 = 0,
    builds: usize = 0,
    fn build(self: *Counter, v: *view.View) anyerror!void {
        self.builds += 1;
        var label: [32]u8 = undefined;
        try v.text(try std.fmt.bufPrint(&label, "Count: {d}", .{self.count}), .{});
        if (try v.button("Add", .{})) self.count += 1;
    }
    fn shows(host: *const view.Host, text: []const u8) bool {
        for (host.view.nodes()) |*node| if (std.mem.eql(u8, node.text, text)) return true;
        return false;
    }
    fn add(host: *const view.Host) u64 {
        for (host.view.nodes()) |*node| if (node.kind == .button) return node.id;
        return 0;
    }
};

test "a window out of sight builds the frame a press or a change waits for once settled" {
    const app = try z.App.init(testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 200, .height = 100 });
    defer _ = window.destroy() catch unreachable;
    var state: Counter = .{};
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&state, Counter.build, storage.buffers(), .{});
    // The pure test backend has no native window for accessibility.
    host.context.semantics_enabled = false;
    try host.attach(window);

    // A window never shown waits to build its first frame.
    try testing.expect(window.outOfSight());
    try testing.expect(host.waitsOutOfSight());
    try testing.expect(host.settle());
    try testing.expect(host.arranged and Counter.shows(&host, "Count: 0"));
    try testing.expect(!window.framePending());

    // The press reaches the view in its event pass; the frame it asks for
    // builds once settled, and reads as pending no more.
    try host.perform(Counter.add(&host), .press);
    try testing.expectEqual(@as(u32, 1), state.count);
    try testing.expect(window.framePending() and !Counter.shows(&host, "Count: 1"));
    try testing.expect(host.settle());
    try testing.expect(Counter.shows(&host, "Count: 1"));
    try testing.expect(!window.framePending() and !window.frameAsked());
    const built = state.builds;
    try testing.expect(!host.settle());
    try testing.expectEqual(built, state.builds);

    // A change of the app's own asks for a frame, which settles too.
    state.count = 5;
    window.invalidate();
    try testing.expect(window.framePending());
    try testing.expect(host.settle());
    try testing.expect(Counter.shows(&host, "Count: 5"));

    // A window that shows paints its frames as the platform asks for them.
    window.show();
    try testing.expect(!window.outOfSight());
    try host.perform(Counter.add(&host), .press);
    try testing.expect(!host.settle());
    try testing.expect(window.framePending() and !Counter.shows(&host, "Count: 6"));
}

const Hiding = struct {
    window: z.Window = undefined,
    hidden_builds: usize = 0,
    fn build(self: *Hiding, v: *view.View) anyerror!void {
        if (v.windowHidden()) self.hidden_builds += 1;
        if (try v.button("Minimize", .{})) try self.window.perform(.minimize);
    }
    fn button(host: *const view.Host) u64 {
        for (host.view.nodes()) |*node| if (node.kind == .button) return node.id;
        return 0;
    }
};

test "a view that asks windowHidden builds hidden after the pass that minimized its window" {
    const app = try z.App.init(testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 200, .height = 100 });
    defer _ = window.destroy() catch unreachable;
    var state: Hiding = .{ .window = window };
    var storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&state, Hiding.build, storage.buffers(), .{});
    host.context.semantics_enabled = false;
    try host.attach(window);
    try testing.expect(host.settle());
    window.show();
    try testing.expect(!window.outOfSight());
    // The pass that minimizes the window read it shown. No frame draws in
    // a minimized window, so the build that sees it hidden comes from the
    // queue once the pass is over, and only once.
    try host.perform(Hiding.button(&host), .press);
    try testing.expect(window.outOfSight());
    try testing.expectEqual(@as(usize, 0), state.hidden_builds);
    try app.dispatch();
    try testing.expectEqual(@as(usize, 1), state.hidden_builds);
    try app.dispatch();
    try testing.expectEqual(@as(usize, 1), state.hidden_builds);
}
