const std = @import("std");
const builtin = @import("builtin");
const publication = @import("publication.zig");

/// Absolute path of the current release's executable under `root_path`.
/// Caller frees.
pub fn currentExecutable(allocator: std.mem.Allocator, root_path: []const u8, identity: []const u8, target: []const u8) ![]u8 {
    var root = try std.fs.cwd().openDir(root_path, .{ .no_follow = true });
    defer root.close();
    const current = try publication.readCurrent(allocator, root, identity, target);
    var relative_buffer: [512]u8 = undefined;
    const relative = try current.relativePath(&relative_buffer);
    const absolute = try std.fs.cwd().realpathAlloc(allocator, root_path);
    defer allocator.free(absolute);
    return std.fs.path.join(allocator, &.{ absolute, relative });
}

/// Start `argv` without waiting for it and without inheriting standard I/O.
/// Used to start a newly published release after the running App has
/// finished shutting down (after `App.run` returns), so no window, callback
/// or update lock of the old process is still live.
pub fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = cwd;
    if (builtin.os.tag != .windows) child.pgid = 0;
    try child.spawn();
    if (builtin.os.tag == .windows) {
        std.os.windows.CloseHandle(child.id);
        std.os.windows.CloseHandle(child.thread_handle);
    }
    // POSIX: the child is reaped by init once this process exits.
}

test "current executable resolves inside the managed root" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("root/releases/linux-x86_64-1.0.0.0");
    try temp.dir.writeFile(.{ .sub_path = "root/current.json", .data = 
        \\{"format":1,"identity":"org.ziggurat.Launch","target":"linux-x86_64","version":{"major":1,"minor":0,"patch":0,"revision":0},"release":"linux-x86_64-1.0.0.0","executable":"app"}
    });
    const base = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const root = try std.fs.path.join(allocator, &.{ base, "root" });
    defer allocator.free(root);
    const path = try currentExecutable(allocator, root, "org.ziggurat.Launch", "linux-x86_64");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "releases" ++ std.fs.path.sep_str ++ "linux-x86_64-1.0.0.0" ++ std.fs.path.sep_str ++ "app") or std.mem.endsWith(u8, path, "releases/linux-x86_64-1.0.0.0/app"));
    try std.testing.expectError(error.PackageIdentityMismatch, currentExecutable(allocator, root, "org.ziggurat.Other", "linux-x86_64"));
}
