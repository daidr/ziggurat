const std = @import("std");
const zio = @import("ziggurat_io");

/// Installed by the setup smoke checks: records its version and arguments in
/// the file named by ZIGGURAT_SETUP_SMOKE_OUT, then exits.
pub const version = @import("setup_fixture_options").version;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const output = try zio.getEnvVarOwned(allocator, "ZIGGURAT_SETUP_SMOKE_OUT");
    const args = try zio.argsAlloc(allocator, init.args);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(allocator, version);
    for (args[1..]) |arg| try text.print(allocator, " {s}", .{arg});
    try text.append(allocator, '\n');
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = output, .data = text.items });
}
