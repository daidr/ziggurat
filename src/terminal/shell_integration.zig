//! Shell integration for zsh: a temporary `ZDOTDIR` whose `.zshenv` puts
//! the user's own `ZDOTDIR` back before sourcing their startup files, then
//! marks the prompt with OSC 133 once the first prompt is about to show,
//! after the user's prompt theme has set it up. The terminal then knows
//! where the prompt is and clears it before the columns change, for zsh
//! to draw it again after SIGWINCH (`Options.shell_integration`). The
//! user's files are never changed; the directory goes when the session
//! does.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const pty = @import("pty.zig");

/// Holds the user's `ZDOTDIR` for the startup file: `1:` and the value
/// when one was set, `0:` when none was.
pub const saved_variable = "ZIGGURAT_TERMINAL_ZDOTDIR";

/// The `.zshenv` the temporary `ZDOTDIR` holds. Prompt themes that emit
/// their own marks when asked (Powerlevel10k) are asked to.
pub const zshenv =
    \\case ${ZIGGURAT_TERMINAL_ZDOTDIR-} in
    \\  1:*) export ZDOTDIR=${ZIGGURAT_TERMINAL_ZDOTDIR#1:} ;;
    \\  *) unset ZDOTDIR ;;
    \\esac
    \\unset ZIGGURAT_TERMINAL_ZDOTDIR
    \\[[ ! -r ${ZDOTDIR-$HOME}/.zshenv ]] || source -- "${ZDOTDIR-$HOME}/.zshenv"
    \\[[ -o interactive ]] || return
    \\
    \\typeset -gi __p9k_force_term_shell_integration=1
    \\
    \\_ziggurat_mark_prompt() {
    \\  local code=$?
    \\  emulate -L zsh
    \\  if ! zle; then
    \\    printf '\e]133;D;%d\a' $code
    \\  fi
    \\  [[ -o promptpercent ]] || return
    \\  local start=$'%{\e]133;A;cl=line;redraw=1\a%}' input=$'%{\e]133;B\a%}'
    \\  local continuation=$'%{\e]133;P;k=s\a%}'
    \\  if [[ $PS1 != *$'\e]133;'* ]]; then
    \\    PS1=$start${PS1//$'\n'/$'\n'$continuation}$input
    \\  fi
    \\  [[ $PS2 == *$'\e]133;'* ]] || PS2=$continuation$PS2$input
    \\}
    \\_ziggurat_command_start() {
    \\  printf '\e]133;C\a'
    \\}
    \\_ziggurat_install_marks() {
    \\  emulate -L zsh
    \\  autoload -Uz add-zsh-hook
    \\  add-zsh-hook -d precmd _ziggurat_install_marks
    \\  add-zsh-hook precmd _ziggurat_mark_prompt
    \\  add-zsh-hook preexec _ziggurat_command_start
    \\  _ziggurat_mark_prompt
    \\}
    \\typeset -ga precmd_functions
    \\precmd_functions+=(_ziggurat_install_marks)
    \\
;

/// Whether `command` runs zsh: its program, or the user's shell when it
/// names none, is called `zsh`.
pub fn runsZsh(command: pty.Command) bool {
    if (builtin.os.tag == .windows) return false;
    const program = if (command.argv.len > 0) command.argv[0] else zio.getenv("SHELL") orelse "/bin/sh";
    return std.mem.eql(u8, std.fs.path.basename(program), "zsh");
}

/// A prepared zsh: the temporary directory and the environment to start
/// the command with.
pub const Zsh = struct {
    allocator: std.mem.Allocator,
    dir: [:0]u8,
    /// The command's variables without `ZDOTDIR`, then the saved one and
    /// the temporary `ZDOTDIR`.
    env: []pty.Variable,
    strings: [2][]u8,

    /// Make the directory and its `.zshenv` for `command`, which keeps
    /// its other variables; the user's `ZDOTDIR` is the command's, else
    /// this process's.
    pub fn prepare(allocator: std.mem.Allocator, command: pty.Command) !Zsh {
        if (builtin.os.tag == .windows) return error.Unsupported;
        var original: ?[]const u8 = zio.getenv("ZDOTDIR");
        for (command.env) |variable| {
            if (std.mem.eql(u8, variable.name, "ZDOTDIR")) original = variable.value;
        }
        const base = zio.getenv("TMPDIR") orelse "/tmp";
        const template = try std.fmt.allocPrintSentinel(allocator, "{s}{s}ziggurat-zsh-XXXXXX", .{ base, if (std.mem.endsWith(u8, base, "/")) "" else "/" }, 0);
        errdefer allocator.free(template);
        if (mkdtemp(template.ptr) == null) return error.SystemResources;
        errdefer _ = std.c.rmdir(template.ptr);
        try writeStartup(template);
        errdefer removeStartup(template);

        const saved = try std.fmt.allocPrint(allocator, "{s}{s}", .{ if (original != null) "1:" else "0:", original orelse "" });
        errdefer allocator.free(saved);
        const dir_copy = try allocator.dupe(u8, template);
        errdefer allocator.free(dir_copy);
        var env: std.ArrayList(pty.Variable) = .empty;
        errdefer env.deinit(allocator);
        for (command.env) |variable| {
            if (std.mem.eql(u8, variable.name, "ZDOTDIR") or std.mem.eql(u8, variable.name, saved_variable)) continue;
            try env.append(allocator, variable);
        }
        try env.append(allocator, .{ .name = saved_variable, .value = saved });
        try env.append(allocator, .{ .name = "ZDOTDIR", .value = dir_copy });
        return .{ .allocator = allocator, .dir = template, .env = try env.toOwnedSlice(allocator), .strings = .{ saved, dir_copy } };
    }

    /// `command` with this environment.
    pub fn apply(self: *const Zsh, command: pty.Command) pty.Command {
        var result = command;
        result.env = self.env;
        return result;
    }

    /// Remove the directory and free what `prepare` made. Safe from any
    /// thread.
    pub fn deinit(self: *Zsh) void {
        removeStartup(self.dir);
        _ = std.c.rmdir(self.dir.ptr);
        for (self.strings) |text| self.allocator.free(text);
        self.allocator.free(self.env);
        self.allocator.free(self.dir);
        self.* = undefined;
    }
};

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn startupPath(dir: []const u8, buffer: *[std.fs.max_path_bytes]u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, "{s}/.zshenv", .{dir}, 0) catch null;
}

fn writeStartup(dir: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = startupPath(dir, &buffer) orelse return error.NameTooLong;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.SystemResources;
    defer _ = std.c.close(fd);
    var rest: []const u8 = zshenv;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) {
            _ = std.c.unlink(path.ptr);
            return error.SystemResources;
        }
        rest = rest[@intCast(n)..];
    }
}

fn removeStartup(dir: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = startupPath(dir, &buffer) orelse return;
    _ = std.c.unlink(path.ptr);
}

test "zsh is recognized by the program's name" {
    // Windows has no zsh integration: runsZsh always answers false there.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(runsZsh(.{ .argv = &.{"/usr/bin/zsh"} }));
    try std.testing.expect(runsZsh(.{ .argv = &.{ "zsh", "-l" } }));
    try std.testing.expect(!runsZsh(.{ .argv = &.{"/bin/bash"} }));
    try std.testing.expect(!runsZsh(.{ .argv = &.{"/opt/zsh-wrapper"} }));
}

test "a prepared zsh keeps the command's variables and saves its ZDOTDIR" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var zsh = try Zsh.prepare(std.testing.allocator, .{ .argv = &.{"zsh"}, .env = &.{ .{ .name = "A", .value = "1" }, .{ .name = "ZDOTDIR", .value = "/home/me/zsh" }, .{ .name = saved_variable, .value = "stale" } } });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = startupPath(zsh.dir, &buffer).?;
    {
        defer zsh.deinit();
        try std.testing.expectEqual(@as(usize, 3), zsh.env.len);
        try std.testing.expectEqualStrings("A", zsh.env[0].name);
        try std.testing.expectEqualStrings(saved_variable, zsh.env[1].name);
        try std.testing.expectEqualStrings("1:/home/me/zsh", zsh.env[1].value);
        try std.testing.expectEqualStrings("ZDOTDIR", zsh.env[2].name);
        try std.testing.expectEqualStrings(zsh.dir, zsh.env[2].value);
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        try std.testing.expect(fd >= 0);
        var contents: [zshenv.len + 1]u8 = undefined;
        const n = std.c.read(fd, &contents, contents.len);
        _ = std.c.close(fd);
        try std.testing.expectEqualStrings(zshenv, contents[0..@intCast(n)]);
    }
    // The directory and its file are gone.
    try std.testing.expect(std.c.access(path.ptr, 0) != 0);
}
