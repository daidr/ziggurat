//! `ziggurat-icon SOURCE.png OUTPUT.ico`: the build step that turns an
//! application's square PNG into the Windows icon its resources embed.
const std = @import("std");
const icon = @import("icon.zig");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) {
        std.debug.print("usage: ziggurat-icon SOURCE.png OUTPUT.ico\n", .{});
        std.process.exit(2);
    }
    const source = try std.fs.cwd().readFileAlloc(allocator, args[1], 64 * 1024 * 1024);
    const ico = icon.pngToIco(allocator, source) catch |err| {
        std.debug.print("{s}: {s}\n", .{ args[1], switch (err) {
            error.IconNotPng => "the icon must be a PNG",
            error.IconNotSquare => "the icon must be square",
            else => @errorName(err),
        } });
        std.process.exit(1);
    };
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = ico });
}
