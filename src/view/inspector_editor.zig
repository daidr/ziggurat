//! Opening the inspector's source link (`file:line`) in the developer's
//! editor: the command `ZIGGURAT_EDITOR` names, else `VISUAL`'s or
//! `EDITOR`'s, given the line the way each editor takes it, or with none
//! of them set the file in the system's default application.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");

pub const Error = error{ NotAFile, NoLine, Unsupported, TooLong } || std.process.SpawnError;

/// A source location split at its last colon: `file` and `line`.
pub const Location = struct {
    file: []const u8,
    line: u64,
    pub fn parse(text: []const u8) ?Location {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
        if (colon == 0) return null;
        const line = std.fmt.parseInt(u64, text[colon + 1 ..], 10) catch return null;
        return .{ .file = text[0..colon], .line = line };
    }
};

/// Whether `location` names a file that is here, so the inspector shows it
/// as a link; a path the build trimmed (`-trimpath`) is not.
pub fn openable(location: []const u8) bool {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return false;
    const at = Location.parse(location) orelse return false;
    if (!std.fs.path.isAbsolute(at.file)) return false;
    const stat = std.Io.Dir.cwd().statFile(zio.io(), at.file, .{}) catch return false;
    return stat.kind == .file;
}

/// How `editor`, a command line as an environment variable holds it, opens
/// `file` at `line`: its words, then the location as that editor takes it.
/// `scratch` holds the location's text.
pub fn command(editor: []const u8, file: []const u8, line: u64, argv: [][]const u8, scratch: []u8) Error![]const []const u8 {
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, editor, " \t");
    while (words.next()) |word| {
        if (count + 3 > argv.len) return error.TooLong;
        argv[count] = word;
        count += 1;
    }
    if (count == 0) return error.Unsupported;
    const name = std.fs.path.stem(argv[0]);
    const is = struct {
        fn any(value: []const u8, comptime names: []const []const u8) bool {
            inline for (names) |known| if (std.ascii.eqlIgnoreCase(value, known)) return true;
            return false;
        }
    };
    if (is.any(name, &.{ "code", "code-insiders", "codium", "cursor", "windsurf" })) {
        // VS Code and its forks: -g file:line.
        argv[count] = "-g";
        argv[count + 1] = std.fmt.bufPrint(scratch, "{s}:{d}", .{ file, line }) catch return error.TooLong;
        return argv[0 .. count + 2];
    }
    if (is.any(name, &.{ "subl", "zed", "hx", "helix", "mate" })) {
        argv[count] = std.fmt.bufPrint(scratch, "{s}:{d}", .{ file, line }) catch return error.TooLong;
        return argv[0 .. count + 1];
    }
    if (is.any(name, &.{ "idea", "goland", "clion", "webstorm", "pycharm", "rider" })) {
        argv[count] = "--line";
        argv[count + 1] = std.fmt.bufPrint(scratch, "{d}", .{line}) catch return error.TooLong;
        argv[count + 2] = file;
        return argv[0 .. count + 3];
    }
    // vi, vim, nvim, emacs, nano, micro, kak, gedit and the rest: +line file.
    argv[count] = std.fmt.bufPrint(scratch, "+{d}", .{line}) catch return error.TooLong;
    argv[count + 1] = file;
    return argv[0 .. count + 2];
}

/// Open `location` (`file:line`) in the editor, without waiting for it.
pub fn open(location: []const u8) Error!void {
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return error.Unsupported;
    const at = Location.parse(location) orelse return error.NoLine;
    if (!openable(location)) return error.NotAFile;
    var env_buffer: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&env_buffer);
    const editor = for ([_][]const u8{ "ZIGGURAT_EDITOR", "VISUAL", "EDITOR" }) |name| {
        const value = zio.getEnvVarOwned(fixed.allocator(), name) catch continue;
        if (std.mem.trim(u8, value, " \t").len > 0) break value;
    } else null;
    var argv: [16][]const u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const words: []const []const u8 = if (editor) |value| try command(value, at.file, at.line, &argv, &scratch) else switch (builtin.os.tag) {
        .macos => &.{ "/usr/bin/open", at.file },
        .windows => &.{ "explorer.exe", at.file },
        else => &.{ "xdg-open", at.file },
    };
    var child = try zio.spawn(.{ .argv = words, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    if (builtin.os.tag == .windows) {
        std.os.windows.CloseHandle(child.id.?);
        std.os.windows.CloseHandle(child.thread_handle);
        return;
    }
    // Reap the editor's launcher when it exits, off the app's thread.
    const thread = std.Thread.spawn(.{}, reap, .{child}) catch {
        child.kill(zio.io());
        return;
    };
    thread.detach();
}
fn reap(child: std.process.Child) void {
    var value = child;
    _ = value.wait(zio.io()) catch {};
}

test "each editor takes the line its own way" {
    var argv: [16][]const u8 = undefined;
    var scratch: [256]u8 = undefined;
    const code = try command("code --wait", "/src/main.zig", 42, &argv, &scratch);
    try std.testing.expectEqual(@as(usize, 4), code.len);
    try std.testing.expectEqualStrings("--wait", code[1]);
    try std.testing.expectEqualStrings("-g", code[2]);
    try std.testing.expectEqualStrings("/src/main.zig:42", code[3]);
    const vim = try command("/usr/bin/nvim", "/src/main.zig", 7, &argv, &scratch);
    try std.testing.expectEqualStrings("+7", vim[1]);
    try std.testing.expectEqualStrings("/src/main.zig", vim[2]);
    const zed = try command("zed", "/src/main.zig", 3, &argv, &scratch);
    try std.testing.expectEqualStrings("/src/main.zig:3", zed[1]);
    try std.testing.expectError(error.Unsupported, command("  ", "/a", 1, &argv, &scratch));
    const at = Location.parse("C:\\src\\main.zig:12").?;
    try std.testing.expectEqualStrings("C:\\src\\main.zig", at.file);
    try std.testing.expectEqual(@as(u64, 12), at.line);
    try std.testing.expect(Location.parse("main.zig") == null);
    try std.testing.expect(!openable("/no/such/file.zig:3"));
}
