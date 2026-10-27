//! Writes the Zig accessors of the catalogs in a directory, as
//! `ziggurat generate` does, for the build's check of the generated code:
//! `i18n-catalog DIR OUTPUT`.
const std = @import("std");
const zio = @import("ziggurat_io");
const i18n_gen = @import("i18n_gen.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    if (args.len != 3) return error.InvalidArguments;
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), args[1], .{ .iterate = true });
    defer dir.close(zio.io());
    const catalog = try i18n_gen.load(allocator, dir, .{ .dir_name = args[1] });
    for (catalog.diagnostics) |d| if (!d.warning) std.debug.print("{f}\n", .{d});
    if (catalog.errors() > 0) return error.CatalogErrors;
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = args[2], .data = try i18n_gen.formattedZig(allocator, &catalog) });
}
