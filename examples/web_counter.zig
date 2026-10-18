const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const html = @embedFile("web_counter.html");

const Counter = struct {
    count: usize = 0,
    fn event(ptr: *anyopaque, view: *web.View, ev: web.Event) void {
        const self: *Counter = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .policy_request, .resources_released => {},
            .process_failed => {
                std.log.err("browser process failed", .{});
                view.window.?.app.quit();
            },
            .message => |message| {
                if (!std.mem.eql(u8, message, "increment")) return;
                self.count +%= 1;
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{self.count}) catch unreachable;
                view.post(text) catch |err| std.log.err("post: {s}", .{@errorName(err)});
            },
            .failed => |hr| {
                std.log.err("WebView2 initialization failed: 0x{x}", .{@as(u32, @bitCast(hr))});
                _ = view.window.?.destroy() catch |err| std.log.err("destroy: {s}", .{@errorName(err)});
            },
            .ready => {},
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "WebCounter" });
    defer allocator.free(profile);
    var counter: Counter = .{};
    var view = web.View.init(allocator, &counter, Counter.event);
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat — WebView counter" });
    view.attach(window, .{ .html = html, .user_data_folder = profile }) catch |err| {
        std.log.err("{s}: HRESULT 0x{x}; run the installed executable beside WebView2Loader.dll", .{ @errorName(err), @as(u32, @bitCast(view.last_hresult)) });
        return err;
    };
    window.show();
    try app.run();
}
