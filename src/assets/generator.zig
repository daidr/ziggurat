const std = @import("std");
const Snapshot = @import("snapshot.zig").Snapshot;

/// Writes into a dedicated build output directory. Content-addressed blobs are
/// written first; assets.zig is atomically published last. No input path escapes
/// into generated source, and the resulting directory is independent of disk
/// source files. Existing unrelated files are never deleted.
pub fn generate(snapshot: *const Snapshot, allocator: std.mem.Allocator, output: std.fs.Dir, entry_path: []const u8) !void {
    const entry = snapshot.find(entry_path) orelse return error.EntryNotFound;
    if (!std.unicode.utf8ValidateSlice(entry.bytes)) return error.InvalidEntryUtf8;
    if (std.mem.indexOfScalar(u8, entry.bytes, 0) != null) return error.EmbeddedNul;
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    render(snapshot, entry_path, entry.digest, &source.writer) catch return error.OutOfMemory;
    for (snapshot.files) |file| {
        var filename: [69]u8 = undefined;
        const blob = try std.fmt.bufPrint(&filename, "{x}.blob", .{&file.digest});
        var atomic = try output.atomicFile(blob, .{ .write_buffer = &.{} });
        defer atomic.deinit();
        try atomic.file_writer.file.writeAll(file.bytes);
        try atomic.finish();
    }
    var atomic = try output.atomicFile("assets.zig", .{ .write_buffer = &.{} });
    defer atomic.deinit();
    try atomic.file_writer.file.writeAll(source.written());
    try atomic.finish();
}

fn render(snapshot: *const Snapshot, entry_path: []const u8, entry_digest: [32]u8, writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.writeAll("// Generated local resources. All bytes are embedded at compile time.\n");
    try writer.print("pub const digest = \"{x}\";\npub const total_bytes = {d};\n", .{ &snapshot.digest, snapshot.total_bytes });
    try writer.print("pub const entry_path = \"{s}\";\n", .{entry_path});
    try writer.print("pub const html: []const u8 = @embedFile(\"{x}.blob\");\n", .{&entry_digest});
    try writer.print("pub fn resourceTable(comptime Resource: type) [{d}]Resource {{\n    return .{{\n", .{snapshot.files.len - 1});
    for (snapshot.files) |file| {
        var filename: [69]u8 = undefined;
        const blob = std.fmt.bufPrint(&filename, "{x}.blob", .{&file.digest}) catch unreachable;
        if (std.mem.eql(u8, file.path, entry_path)) continue;
        // Snapshot paths and MIME are validated ASCII without string escapes.
        try writer.print("        .{{ .path = \"{s}\", .mime = \"{s}\", .bytes = @embedFile(\"{s}\") }},\n", .{ file.path, file.mime, blob });
    }
    try writer.writeAll("    };\n}\n");
}

test "generation embeds binary bytes and deterministically publishes independent source" {
    var input = std.testing.tmpDir(.{ .iterate = true });
    defer input.cleanup();
    var output = std.testing.tmpDir(.{});
    defer output.cleanup();
    try input.dir.writeFile(.{ .sub_path = "index.html", .data = "<html>entry</html>" });
    try input.dir.writeFile(.{ .sub_path = "binary.bin", .data = "\x00\xff\x01" });
    var snapshot = try Snapshot.load(std.testing.allocator, input.dir, .{});
    defer snapshot.deinit();
    try generate(&snapshot, std.testing.allocator, output.dir, "/index.html");
    const first = try output.dir.readFileAlloc(std.testing.allocator, "assets.zig", 64 * 1024);
    defer std.testing.allocator.free(first);
    try generate(&snapshot, std.testing.allocator, output.dir, "/index.html");
    const second = try output.dir.readFileAlloc(std.testing.allocator, "assets.zig", 64 * 1024);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, generate(&snapshot, failing.allocator(), output.dir, "/index.html"));
    const after_failure = try output.dir.readFileAlloc(std.testing.allocator, "assets.zig", 64 * 1024);
    defer std.testing.allocator.free(after_failure);
    try std.testing.expectEqualStrings(first, after_failure);
    try std.testing.expect(std.mem.indexOf(u8, first, "[1]Resource") != null);
    var filename: [69]u8 = undefined;
    const blob = try std.fmt.bufPrint(&filename, "{x}.blob", .{&snapshot.find("/binary.bin").?.digest});
    try input.dir.deleteFile("binary.bin");
    const bytes = try output.dir.readFileAlloc(std.testing.allocator, blob, 10);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x00\xff\x01", bytes);
    try std.testing.expectError(error.EntryNotFound, generate(&snapshot, std.testing.allocator, output.dir, "/missing"));
}
