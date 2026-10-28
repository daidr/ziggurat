const std = @import("std");
const zio = @import("ziggurat_io");
const assets = @import("ziggurat_assets");

/// web-assets INPUT_DIRECTORY OUTPUT_DIRECTORY [ENTRY_PATH]
/// INPUT is a built frontend; OUTPUT is a dedicated build-generated directory.
pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    if (args.len < 3 or args.len > 4) return error.ExpectedInputAndOutputDirectory;
    var input = try std.Io.Dir.cwd().openDir(zio.io(), args[1], .{ .iterate = true, .follow_symlinks = false });
    defer input.close(zio.io());
    if ((try input.stat(zio.io())).kind != .directory) return error.NonRegularAsset;
    var snapshot = try assets.Snapshot.load(allocator, input, .{});
    defer snapshot.deinit();
    var output = try std.Io.Dir.cwd().createDirPathOpen(zio.io(), args[2], .{});
    defer output.close(zio.io());
    const input_path = try zio.realPathAlloc(input, ".", allocator);
    const output_path = try zio.realPathAlloc(output, ".", allocator);
    const relative_output = try std.fs.path.relativeAlloc(allocator, input_path, null, input_path, output_path);
    if (!std.fs.path.isAbsolute(relative_output)) {
        var segments = std.mem.tokenizeAny(u8, relative_output, "/\\");
        const first = segments.next();
        if (first == null or !std.mem.eql(u8, first.?, "..")) return error.OutputInsideInput;
    }
    try assets.generate(&snapshot, allocator, output, if (args.len == 4) args[3] else "/index.html");
}
