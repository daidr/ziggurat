//! Writes the Zig accessors of the catalogs in a directory, as
//! `ziggurat generate` does, for the build's check of the generated code:
//! `i18n-catalog DIR OUTPUT`.
const std = @import("std");
const i18n_gen = @import("i18n_gen.zig");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) return error.InvalidArguments;
    var dir = try std.fs.cwd().openDir(args[1], .{ .iterate = true });
    defer dir.close();
    const catalog = try i18n_gen.load(allocator, dir, .{ .dir_name = args[1] });
    for (catalog.diagnostics) |d| if (!d.warning) std.debug.print("{f}\n", .{d});
    if (catalog.errors() > 0) return error.CatalogErrors;
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = try i18n_gen.formattedZig(allocator, &catalog) });
}
