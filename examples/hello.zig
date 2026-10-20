const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");

const Hello = struct {
    fn build(_: *Hello, v: *view.View) anyerror!void {
        try v.text("Hello", .{});
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var hello: Hello = .{};
    var storage: view.Storage(16, 256) = .{};
    var host = view.Host.init(&hello, Hello.build, storage.buffers(), .{});
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Hello" });
    try host.attach(window);
    window.show();
    try app.run();
}
