const std = @import("std");
const zio = @import("ziggurat_io");
const ipc = @import("ipc");
const fixture = @import("fixture");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOutputPath;
    const source = try ipc.generate(fixture.Service, allocator);
    defer allocator.free(source);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = args[1], .data = source });
}
