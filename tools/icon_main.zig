//! `ziggurat-icon SOURCE.png OUTPUT.ico`: the build step that turns an
//! application's square PNG into the Windows icon its resources embed.
const std = @import("std");
const zio = @import("ziggurat_io");
const icon = @import("icon.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    if (args.len != 3) {
        std.debug.print("usage: ziggurat-icon SOURCE.png OUTPUT.ico\n", .{});
        std.process.exit(2);
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(zio.io(), args[1], allocator, .limited(64 * 1024 * 1024));
    const ico = icon.pngToIco(allocator, source) catch |err| {
        std.debug.print("{s}: {s}\n", .{ args[1], switch (err) {
            error.IconNotPng => "the icon must be a PNG",
            error.IconNotSquare => "the icon must be square",
            else => @errorName(err),
        } });
        std.process.exit(1);
    };
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = args[2], .data = ico });
}
