//! The application's Windows jump list: the menu of its taskbar button. It
//! holds the Tasks category, links that run a program (the application
//! itself by default) whether or not the application is running, and
//! optionally the Recent category, which the shell fills from the documents
//! recorded with `recent.addToSystem`.
//!
//! Windows replaces the whole list on every change and keeps it after the
//! application exits, so applications usually set it once at startup. A task
//! that acts on the application is best one of its own URL schemes as the
//! argument: with `instance.claimOrForward` the running instance receives it.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const identity = @import("identity.zig");
const integration = @import("integration.zig");

const windows = builtin.os.tag == .windows;

pub const capabilities = .{ .tasks = windows };

/// The most tasks accepted; the shell shows only as many as fit.
pub const max_tasks = 32;
/// Byte limit of every text field, below the shell link limits.
pub const max_text_bytes = 259;

pub const Task = struct {
    /// Required label.
    title: []const u8,
    /// Tooltip.
    description: []const u8 = "",
    /// Absolute program path; null runs this executable.
    path: ?[]const u8 = null,
    /// Passed as they are; quoted for the command line.
    arguments: []const []const u8 = &.{},
    working_directory: []const u8 = "",
    /// File holding the icon; empty uses the program's own icon.
    icon_path: []const u8 = "",
    icon_index: i32 = 0,
};

pub const Options = struct {
    /// The AppUserModelID whose list this is; null is this process's own,
    /// which `identity.setProcessIdentity` sets.
    app_id: ?[]const u8 = null,
    /// Also show the Recent category.
    recent: bool = false,
};

extern fn ziggurat_system_jump_list_begin(app_id: ?[*:0]const u16, out: *?*anyopaque) callconv(.c) i32;
extern fn ziggurat_system_jump_list_add(list: *anyopaque, title: [*:0]const u16, description: [*:0]const u16, path: [*:0]const u16, arguments: [*:0]const u16, directory: [*:0]const u16, icon: [*:0]const u16, icon_index: c_int) callconv(.c) i32;
extern fn ziggurat_system_jump_list_finish(list: *anyopaque, commit: c_int, recent: c_int) callconv(.c) i32;
extern fn ziggurat_system_jump_list_delete(app_id: ?[*:0]const u16) callconv(.c) i32;

/// Checks a task list without touching the system.
pub fn validate(tasks: []const Task, options: Options) !void {
    if (options.app_id) |id| try identity.validate(id);
    if (tasks.len > max_tasks) return error.TooManyTasks;
    for (tasks) |task| {
        if (task.title.len == 0) return error.MissingTitle;
        for ([_][]const u8{ task.title, task.description, task.path orelse "", task.working_directory, task.icon_path }) |text| try validateText(text);
        if (task.path) |path| if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        if (task.arguments.len > 32) return error.TooManyArguments;
        for (task.arguments) |argument| try validateText(argument);
    }
}
fn validateText(text: []const u8) !void {
    if (text.len > max_text_bytes) return error.TextTooLong;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
}

/// Quoted arguments without the program, as a shell link takes them.
pub fn argumentLine(buffer: []u8, arguments: []const []const u8) ![]u8 {
    // The executable slot is empty: `""`, then a space per argument.
    const line = try integration.windowsCommand(buffer, "", arguments, false);
    return if (line.len > 3) line[3..] else line[2..];
}

/// Replaces the application's jump list with `tasks`, plus the Recent
/// category when asked. No tasks and no Recent category removes the list.
/// Blocking COM calls: run it at startup or on a worker, not per frame. It
/// initializes COM on the calling thread when needed.
pub fn setTasks(allocator: std.mem.Allocator, tasks: []const Task, options: Options) !void {
    try validate(tasks, options);
    if (comptime !windows) return error.UnsupportedCapability;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const app_id: ?[*:0]const u16 = if (options.app_id) |id| (try std.unicode.utf8ToUtf16LeAllocZ(arena, id)).ptr else null;
    if (tasks.len == 0 and !options.recent) {
        if (ziggurat_system_jump_list_delete(app_id) < 0) return error.JumpListUnavailable;
        return;
    }
    const self_path = try zio.executablePathAlloc(arena);
    var list: ?*anyopaque = null;
    if (ziggurat_system_jump_list_begin(app_id, &list) < 0) return error.JumpListUnavailable;
    var committed = false;
    defer if (!committed) {
        _ = ziggurat_system_jump_list_finish(list.?, 0, 0);
    };
    var line: [32 * 1024]u8 = undefined;
    for (tasks) |task| {
        const arguments = try argumentLine(&line, task.arguments);
        if (ziggurat_system_jump_list_add(
            list.?,
            try wide(arena, task.title),
            try wide(arena, task.description),
            try wide(arena, task.path orelse self_path),
            try wide(arena, arguments),
            try wide(arena, task.working_directory),
            try wide(arena, task.icon_path),
            task.icon_index,
        ) < 0) return error.JumpListUnavailable;
    }
    committed = true;
    if (ziggurat_system_jump_list_finish(list.?, 1, @intFromBool(options.recent)) < 0) return error.JumpListUnavailable;
}
fn wide(arena: std.mem.Allocator, text: []const u8) ![*:0]const u16 {
    return (try std.unicode.utf8ToUtf16LeAllocZ(arena, text)).ptr;
}

test "jump list tasks are validated before the system is touched" {
    const ok: Task = .{ .title = "New note", .arguments = &.{"example-notes://new"} };
    try validate(&.{ok}, .{});
    try std.testing.expectError(error.MissingTitle, validate(&.{.{ .title = "" }}, .{}));
    try std.testing.expectError(error.InvalidText, validate(&.{.{ .title = "a\nb" }}, .{}));
    try std.testing.expectError(error.RelativePath, validate(&.{.{ .title = "a", .path = "bin/app" }}, .{}));
    try std.testing.expectError(error.InvalidIdentity, validate(&.{ok}, .{ .app_id = "bad id" }));
    const many: [max_tasks + 1]Task = @splat(ok);
    try std.testing.expectError(error.TooManyTasks, validate(&many, .{}));
}

test "task arguments are quoted without a program" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try argumentLine(&buffer, &.{}));
    try std.testing.expectEqualStrings("\"a b\" \"c\\\"d\" \"e\\\\\"", try argumentLine(&buffer, &.{ "a b", "c\"d", "e\\" }));
}
