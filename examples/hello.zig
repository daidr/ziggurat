//! The smallest Ziggurat app: one window with a heading, a line of text and
//! a button that changes the greeting. The build function describes the
//! whole view from `Hello`'s state; the button returns true on the pass that
//! activates it, and the view repaints on its own.
//!
//! Run it with `zig build run-hello`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");

const greetings = [_][]const u8{ "Hello, world!", "Hi there!", "Welcome to Ziggurat.", "Good to see you." };

const Hello = struct {
    index: usize = 0,

    fn build(self: *Hello, v: *view.View) anyerror!void {
        try v.text("Hello", .{ .font = view.Font.heading1 });
        try v.text(greetings[self.index], .{});
        if (try v.button("Greet again", .{})) self.index = (self.index + 1) % greetings.len;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // The state, the view's fixed storage and the Host stay at stable
    // addresses for as long as the window shows them.
    var hello: Hello = .{};
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&hello, Hello.build, storage.buffers(), .{});

    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Hello", .width = 420, .height = 240 });
    try host.attach(window);
    window.show();
    // Returns once the last window closes.
    try app.run();
}

test "the button changes the greeting" {
    var hello: Hello = .{};
    var storage: view.Storage(16, 256) = .{};
    var h = view.Harness.init(&hello, Hello.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "Greet again" });
    try std.testing.expectEqual(@as(usize, 1), hello.index);
    _ = try h.find(.{ .text = "Hi there!" });
}
