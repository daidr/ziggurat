const std = @import("std");
const ipc = @import("ziggurat_ipc");
const Service = @import("service").Service;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 2) return error.OutputPathRequired;
    const client = try ipc.generate(Service, allocator);
    try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = client });
}
