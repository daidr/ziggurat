const std = @import("std");
const ipc = @import("ipc");
const fixture = @import("fixture");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOutputPath;
    const source = try ipc.generate(fixture.Service, allocator);
    defer allocator.free(source);
    try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = source });
}
