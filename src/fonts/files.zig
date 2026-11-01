//! The file a registered font is read from: `<cache>/ziggurat/fonts/<hash>.font`,
//! written once, through a temporary file of its own renamed into place, so
//! processes registering the same font at once never share one.
const std = @import("std");
const zio = @import("ziggurat_io");

pub fn write(allocator: std.mem.Allocator, cache: []const u8, data: []const u8, hash: *const [16]u8) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ cache, "ziggurat", "fonts" });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(zio.io(), dir);
    const hex = std.fmt.bytesToHex(hash.*, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.font", .{ dir, std.fs.path.sep, &hex });
    errdefer allocator.free(path);
    if (std.Io.Dir.cwd().access(zio.io(), path, .{})) |_| return path else |_| {}
    var unique: [8]u8 = undefined;
    zio.random.bytes(&unique);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, &std.fmt.bytesToHex(unique, .lower) });
    defer allocator.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(zio.io(), temporary) catch {};
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = temporary, .data = data });
    std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, zio.io()) catch |err| {
        // Another process put the same font in place first.
        std.Io.Dir.cwd().access(zio.io(), path, .{}) catch return err;
        std.Io.Dir.cwd().deleteFile(zio.io(), temporary) catch {};
    };
    return path;
}

test "processes writing the same font at once each finish with it in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try tmp.dir.realPathFileAlloc(zio.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(cache);
    const hash: [16]u8 = @splat(7);
    const Writer = struct {
        fn run(dir: []const u8, out: *?anyerror) void {
            const path = write(std.heap.page_allocator, dir, "font bytes", &hash) catch |err| {
                out.* = err;
                return;
            };
            std.heap.page_allocator.free(path);
        }
    };
    var failures: [8]?anyerror = @splat(null);
    var threads: [8]std.Thread = undefined;
    for (&threads, &failures) |*thread, *failure| thread.* = try std.Thread.spawn(.{}, Writer.run, .{ cache, failure });
    for (threads) |thread| thread.join();
    for (failures) |failure| try std.testing.expectEqual(@as(?anyerror, null), failure);
    const path = try write(std.testing.allocator, cache, "font bytes", &hash);
    defer std.testing.allocator.free(path);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("font bytes", try std.Io.Dir.cwd().readFile(zio.io(), path, &buffer));
    // No temporary file is left behind.
    var fonts = try tmp.dir.openDir(zio.io(), "ziggurat/fonts", .{ .iterate = true });
    defer fonts.close(zio.io());
    var entries = fonts.iterate();
    var count: usize = 0;
    while (try entries.next(zio.io())) |_| count += 1;
    try std.testing.expectEqual(1, count);
}
