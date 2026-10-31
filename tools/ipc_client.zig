const std = @import("std");
const zio = @import("ziggurat_io");
const ipc = @import("ziggurat_ipc");
const Service = @import("service").Service;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    if (args.len != 2) return error.OutputPathRequired;
    const client = try ipc.generate(Service, allocator);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = args[1], .data = client });
}
