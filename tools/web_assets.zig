const std = @import("std");
const assets = @import("ziggurat_assets");

/// web-assets INPUT_DIRECTORY OUTPUT_DIRECTORY [ENTRY_PATH]
/// INPUT is a built frontend; OUTPUT is a dedicated build-generated directory.
pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3 or args.len > 4) return error.ExpectedInputAndOutputDirectory;
    var input = try std.fs.cwd().openDir(args[1], .{ .iterate = true, .no_follow = true });
    defer input.close();
    if ((try (std.fs.File{ .handle = input.fd }).stat()).kind != .directory) return error.NonRegularAsset;
    var snapshot = try assets.Snapshot.load(allocator, input, .{});
    defer snapshot.deinit();
    var output = try std.fs.cwd().makeOpenPath(args[2], .{});
    defer output.close();
    const input_path = try input.realpathAlloc(allocator, ".");
    const output_path = try output.realpathAlloc(allocator, ".");
    const relative_output = try std.fs.path.relative(allocator, input_path, output_path);
    if (!std.fs.path.isAbsolute(relative_output)) {
        var segments = std.mem.tokenizeAny(u8, relative_output, "/\\");
        const first = segments.next();
        if (first == null or !std.mem.eql(u8, first.?, "..")) return error.OutputInsideInput;
    }
    try assets.generate(&snapshot, allocator, output, if (args.len == 4) args[3] else "/index.html");
}
