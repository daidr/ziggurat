//! ziggurat-automation drives a running Ziggurat app through the socket of
//! its automation module, made for AI coding agents: compact text
//! snapshots of a window's elements with short refs (@e1), actions on
//! them, and diffs of what the window shows once it settled.
//!
//!     zig build automation-cli
//!     ziggurat-automation skills
//!
//! `skills` prints the guide, SKILL.md, built into the command so that it
//! matches the commands of the version built. See docs/automation.md.
const std = @import("std");
const zio = @import("ziggurat_io");
const cli = @import("ziggurat_automation_cli");
const options = @import("automation_cli_options");

pub const skill = @embedFile("SKILL.md");

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try zio.argsAlloc(arena, init.args);
    const argv = try arena.alloc([]const u8, all.len);
    for (all, argv) |arg, *slot| slot.* = arg;
    var out_buffer: [64 * 1024]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(zio.io(), &out_buffer);
    var stderr = std.Io.File.stderr().writer(zio.io(), &err_buffer);
    var stdin = std.Io.File.stdin().reader(zio.io(), &in_buffer);
    return cli.run(std.heap.page_allocator, argv[1..], &stdin.interface, &stdout.interface, &stderr.interface, .{ .skill = skill, .version = options.version });
}

test "skills prints SKILL.md as it is, and the guide tells of every command" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expectEqual(@as(u8, 0), cli.run(std.testing.allocator, &.{"skills"}, null, &out.writer, &errors.writer, .{ .skill = skill }));
    try std.testing.expectEqualStrings(skill, out.written());
    try std.testing.expectEqual(@as(usize, 0), errors.written().len);
    try std.testing.expect(std.mem.startsWith(u8, skill, "---\nname: ziggurat-automation\ndescription: "));
    for (cli.commands) |command| {
        var a: [64]u8 = undefined;
        var b: [64]u8 = undefined;
        const spaced = try std.fmt.bufPrint(&a, "`{s} ", .{command.name});
        const alone = try std.fmt.bufPrint(&b, "`{s}`", .{command.name});
        if (std.mem.indexOf(u8, skill, spaced) == null and std.mem.indexOf(u8, skill, alone) == null) {
            std.debug.print("SKILL.md does not tell of {s}\n", .{command.name});
            return error.TestUnexpectedResult;
        }
    }
}
