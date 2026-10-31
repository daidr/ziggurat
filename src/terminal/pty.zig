//! What a pseudo-terminal runs and how big it is, shared by the platform
//! implementations: a Unix PTY on Linux and a pseudo console on Windows.
const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// The whole grid in pixels, for programs that ask; 0 when unknown.
    width: u16 = 0,
    height: u16 = 0,
};

pub const Variable = struct { name: []const u8, value: []const u8 };

pub const Command = struct {
    /// The program and its arguments; empty runs the user's shell: `SHELL`
    /// or `/bin/sh` on Linux, `COMSPEC` or `cmd.exe` on Windows.
    argv: []const []const u8 = &.{},
    /// Working directory; null inherits this process's.
    cwd: ?[]const u8 = null,
    /// Set in the inherited environment, replacing variables of the same
    /// name.
    env: []const Variable = &.{},
    size: Size = .{},
    /// `TERM` on Linux, unless `env` sets it.
    term: []const u8 = "xterm-256color",
};

/// How the program ended.
pub const Exit = union(enum) {
    code: u32,
    /// Killed by a signal on Linux.
    signal: u32,
};

pub const Error = error{ Unsupported, SpawnFailed, OutOfMemory, InvalidCommand, SystemResources };

pub const Pty = switch (builtin.os.tag) {
    // POSIX pseudo-terminals: Linux and macOS share one implementation.
    .linux, .macos => @import("pty_linux.zig").Pty,
    .windows => @import("pty_windows.zig").Pty,
    else => Unsupported,
};

const Unsupported = struct {
    pub fn spawn(_: std.mem.Allocator, _: Command) Error!Unsupported {
        return error.Unsupported;
    }
};
