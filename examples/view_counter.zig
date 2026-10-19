const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");

const Counter = struct {
    count: i64 = 0,
    step: f64 = 1,
    wrap: bool = false,

    fn build(self: *Counter, v: *view.View) anyerror!void {
        try v.text("Ziggurat / declarative view", .{});
        try v.textf("Count: {d}", .{self.count}, .{ .color = 0x276aa5 });
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("-", .{ .width = 44 })) self.count -= @intFromFloat(self.step);
        if (try v.button("+", .{ .width = 44 })) self.count += @intFromFloat(self.step);
        if (try v.button("Reset", .{ .enabled = self.count != 0 })) self.count = 0;
        try v.end();
        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        try v.textf("Step {d}", .{@as(i64, @intFromFloat(self.step))}, .{ .width = 72 });
        _ = try v.slider(&self.step, .{ .minimum = 1, .maximum = 10, .step = 1 }, .{ .grow = 1 });
        try v.end();
        _ = try v.checkbox(&self.wrap, "Wrap at 100", .{});
        if (self.wrap) self.count = @mod(self.count, 100);
        try v.progress(@as(f32, @floatFromInt(@mod(self.count, 100))) / 100, .{ .self_align = .stretch, .name = "Count within one hundred" });
        try v.spacer(.{});
        try v.text("Tab to focus; Enter or Space to activate; arrows adjust the step.", .{ .color = 0x536475 });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var counter: Counter = .{};
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&counter, Counter.build, storage.buffers(), .{});
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat — Declarative counter" });
    try host.attach(window);
    window.show();
    try app.run();
}
