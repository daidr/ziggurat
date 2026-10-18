const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

const Counter = struct {
    count: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        frame.clear(0xf8f7f3);
        frame.label(.{ .x = 32, .y = 24, .width = 600, .height = 30 }, "Ziggurat / Zig native UI", 0x182430);
        var buffer: [80]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Count: {d}", .{self.count}) catch unreachable;
        frame.label(.{ .x = 32, .y = 72, .width = 600, .height = 30 }, text, 0x182430);
        frame.button(1, .{ .x = 32, .y = 128, .width = 180, .height = 44 }, "Increment") catch unreachable;
        frame.label(.{ .x = 32, .y = 200, .width = 600, .height = 30 }, "Tab to focus; Enter or Space to activate.", 0x536475);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        if (id == 1) self.count +%= 1;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var counter: Counter = .{};
    var content = ui.Context.init(&counter, Counter.draw, Counter.action);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat — Native counter" });
    try content.attach(window);
    window.show();
    try app.run();
}
