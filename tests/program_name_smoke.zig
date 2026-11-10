//! Linux: the app is the program of its executable by whichever name starts
//! it. Started through a link of another name, as the packages put in
//! /usr/bin for each command, GLib's program name, after which GTK names the
//! windows' class and WebKitGTK the directories of the pages' data, is still
//! the executable's; a name the app sets first stays.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");

extern "glib-2.0" fn g_get_prgname() ?[*:0]const u8;

const allocator = std.heap.page_allocator;

pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag != .linux) return;
    const arguments = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, arguments);
    if (arguments.len >= 2 and std.mem.eql(u8, arguments[1], "--child")) {
        if (arguments.len == 3) try system.identity.setProcessIdentity(arguments[2]);
        const app = try z.App.init(allocator);
        defer app.deinit();
        try std.Io.File.stdout().writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "program: {s}\n", .{std.mem.sliceTo(g_get_prgname() orelse "", 0)}));
        return;
    }
    const executable = try zio.executablePathAlloc(allocator);
    var temporary = zio.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.symLink(zio.io(), executable, "another-name", .{});
    const link = try zio.realPathAlloc(temporary.dir, ".", allocator);
    const link_path = try std.fs.path.join(allocator, &.{ link, "another-name" });
    const expected = try std.fmt.allocPrint(allocator, "program: {s}\n", .{std.fs.path.basename(executable)});
    for ([_][]const u8{ executable, link_path }) |started| {
        const result = try zio.run(allocator, .{ .argv = &.{ started, "--child" } });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("started as {s}: {any}\n{s}\n", .{ started, result.term, result.stderr });
            return error.ChildFailed;
        }
        std.testing.expectEqualStrings(expected, result.stdout) catch |err| {
            std.debug.print("started as {s}\n", .{started});
            return err;
        };
    }
    // The identity the app gives itself wins over the executable's name.
    const named = try zio.run(allocator, .{ .argv = &.{ link_path, "--child", "org.zg.ProgramName" } });
    try std.testing.expectEqualStrings("program: org.zg.ProgramName\n", named.stdout);
    std.debug.print("program name smoke passed: the executable's name started directly and through a link of another name; an explicit identity stays\n", .{});
}
