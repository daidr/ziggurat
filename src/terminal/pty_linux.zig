//! A Unix pseudo-terminal: the program runs in a new session with the PTY's
//! secondary side as its controlling terminal, and this process keeps the
//! primary side, non-blocking, for the session's workers.
const std = @import("std");
const posix = std.posix;
const pty = @import("pty.zig");

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn sigprocmask(how: c_int, set: ?*const posix.sigset_t, old: ?*posix.sigset_t) c_int;

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    reaped: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, command: pty.Command) pty.Error!Pty {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Everything the child needs is prepared before fork, which leaves
        // it only async-signal-safe calls.
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const args: []const []const u8 = if (command.argv.len > 0) command.argv else &.{shell};
        const argv = try arena.allocSentinel(?[*:0]const u8, args.len, null);
        for (args, 0..) |arg, i| argv[i] = try arena.dupeZ(u8, arg);
        const envp = try environment(arena, command);
        const cwd: ?[*:0]const u8 = if (command.cwd) |dir| try arena.dupeZ(u8, dir) else null;

        const master = posix_openpt(@bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }));
        if (master < 0) return error.SystemResources;
        errdefer posix.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.SystemResources;
        var name: [128]u8 = undefined;
        if (ptsname_r(master, &name, name.len) != 0) return error.SystemResources;
        const secondary: [*:0]const u8 = @ptrCast(&name);
        setSize(master, command.size);

        const pid = posix.fork() catch return error.SpawnFailed;
        if (pid == 0) child(secondary, argv, envp, cwd);
        // Workers wait on the primary side with poll.
        const flags = posix.fcntl(master, posix.F.GETFL, 0) catch return error.SystemResources;
        _ = posix.fcntl(master, posix.F.SETFL, flags | @as(usize, @as(u32, @bitCast(posix.O{ .NONBLOCK = true })))) catch return error.SystemResources;
        return .{ .master = master, .pid = pid };
    }

    fn child(secondary: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) noreturn {
        // Signal dispositions and the mask are inherited across exec.
        var empty = posix.sigemptyset();
        _ = sigprocmask(posix.SIG.SETMASK, &empty, null);
        for ([_]u8{ posix.SIG.PIPE, posix.SIG.INT, posix.SIG.QUIT, posix.SIG.CHLD, posix.SIG.HUP, posix.SIG.TERM }) |sig| {
            const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
            posix.sigaction(sig, &default, null);
        }
        _ = std.c.setsid();
        const fd = std.c.open(secondary, @bitCast(posix.O{ .ACCMODE = .RDWR }));
        if (fd < 0) std.c._exit(126);
        _ = std.c.ioctl(fd, posix.T.IOCSCTTY, @as(c_int, 0));
        for (0..3) |target| _ = std.c.dup2(fd, @intCast(target));
        if (fd > 2) _ = std.c.close(fd);
        if (cwd) |dir| _ = std.c.chdir(dir);
        _ = execvpe(argv[0].?, argv, envp);
        std.c._exit(127);
    }

    pub fn read(self: *const Pty, buffer: []u8) !usize {
        return posix.read(self.master, buffer) catch |err| switch (err) {
            // The secondary side closed: every program using it is gone.
            error.InputOutput => 0,
            else => err,
        };
    }

    pub fn write(self: *const Pty, bytes: []const u8) !usize {
        return posix.write(self.master, bytes);
    }

    pub fn resize(self: *const Pty, size: pty.Size) void {
        setSize(self.master, size);
    }

    /// Signal the program's process group, and the program itself in case
    /// it left the group.
    pub fn signal(self: *const Pty, sig: u8) void {
        posix.kill(-self.pid, sig) catch {};
        posix.kill(self.pid, sig) catch {};
    }

    /// The exit once the program ended, waiting for it when `block`.
    pub fn wait(self: *Pty, block: bool) ?pty.Exit {
        if (self.reaped) return null;
        const result = posix.waitpid(self.pid, if (block) 0 else posix.W.NOHANG);
        if (result.pid == 0) return null;
        self.reaped = true;
        const status = result.status;
        if (posix.W.IFEXITED(status)) return .{ .code = posix.W.EXITSTATUS(status) };
        if (posix.W.IFSIGNALED(status)) return .{ .signal = posix.W.TERMSIG(status) };
        return .{ .code = 0 };
    }

    pub fn close(self: *Pty) void {
        posix.close(self.master);
    }
};

fn setSize(fd: posix.fd_t, size: pty.Size) void {
    var value: posix.winsize = .{ .row = size.rows, .col = size.cols, .xpixel = size.width, .ypixel = size.height };
    _ = std.c.ioctl(fd, posix.T.IOCSWINSZ, &value);
}

/// This process's environment with the command's variables and the
/// terminal's own on top.
fn environment(arena: std.mem.Allocator, command: pty.Command) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    const own = [_]pty.Variable{ .{ .name = "TERM", .value = command.term }, .{ .name = "COLORTERM", .value = "truecolor" } };
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const text = std.mem.span(entry);
        const name = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
        if (replaced(name, command.env) or replaced(name, &own)) continue;
        try list.append(arena, entry);
    }
    for (own) |variable| if (!replaced(variable.name, command.env)) try list.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ variable.name, variable.value }, 0));
    for (command.env) |variable| {
        if (variable.name.len == 0 or std.mem.indexOfScalar(u8, variable.name, '=') != null) return error.InvalidCommand;
        try list.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ variable.name, variable.value }, 0));
    }
    try list.append(arena, null);
    return @ptrCast(list.items.ptr);
}

fn replaced(name: []const u8, variables: []const pty.Variable) bool {
    for (variables) |variable| if (std.mem.eql(u8, variable.name, name)) return true;
    return false;
}

test "a program runs on the terminal and its output and exit come back" {
    var p = try Pty.spawn(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "test -t 0 && printf \"$TERM:$ZT\"; stty size; exit 3" }, .env = &.{.{ .name = "ZT", .value = "yes" }}, .size = .{ .cols = 33, .rows = 7 } });
    defer p.close();
    var output: [256]u8 = undefined;
    var len: usize = 0;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = p.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 5000);
        const n = p.read(output[len..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;
        len += n;
    }
    try std.testing.expectEqualStrings("xterm-256color:yes7 33\r\n", output[0..len]);
    try std.testing.expectEqual(pty.Exit{ .code = 3 }, p.wait(true).?);
}
