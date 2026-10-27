//! Thin POSIX calls on raw descriptors for code that works below `std.Io`:
//! terminals, sandboxes and descriptor-passing tests. Each call reports
//! failure as an error instead of an errno.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const c = std.c;
const libc = builtin.link_libc;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const mode_t = posix.mode_t;

pub const Error = error{
    AccessDenied,
    PathAlreadyExists,
    FileNotFound,
    NotDir,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NoSpaceLeft,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ReadOnlyFileSystem,
    NotConnected,
    InvalidArgument,
    BadDescriptor,
    WouldBlock,
    ConnectionAborted,
    ConnectionRefused,
    ConnectionResetByPeer,
    BrokenPipe,
    Unexpected,
};

fn check(rc: anytype) Error!void {
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => error.AccessDenied,
        .EXIST => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        .NOTCONN => error.NotConnected,
        .INVAL => error.InvalidArgument,
        .BADF => error.BadDescriptor,
        .AGAIN => error.WouldBlock,
        .CONNABORTED => error.ConnectionAborted,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn retrying(comptime f: anytype, args: anytype) @TypeOf(@call(.auto, f, args)) {
    while (true) {
        const rc = @call(.auto, f, args);
        if (posix.errno(rc) != .INTR) return rc;
    }
}

/// Closes a descriptor, ignoring failure as the descriptor is gone either way.
pub fn close(fd: fd_t) void {
    _ = posix.system.close(fd);
}

pub fn dup(fd: fd_t) Error!fd_t {
    const rc = posix.system.dup(fd);
    try check(rc);
    return @intCast(rc);
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) Error!usize {
    const rc = if (libc) c.fcntl(fd, cmd, arg) else linux.fcntl(fd, cmd, arg);
    try check(rc);
    return @intCast(rc);
}

/// The parts of a descriptor's status the callers check.
pub const Status = struct { dev: u64, ino: u64, mode: u32, uid: u32, nlink: u64 };

pub fn fstat(fd: fd_t) Error!Status {
    if (builtin.os.tag == .linux) {
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .INO = true, .NLINK = true };
        try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &st));
        return .{ .dev = (@as(u64, st.dev_major) << 32) | st.dev_minor, .ino = st.ino, .mode = st.mode, .uid = st.uid, .nlink = st.nlink };
    }
    var st: c.Stat = undefined;
    try check(c.fstat(fd, &st));
    return .{ .dev = @intCast(st.dev), .ino = @intCast(st.ino), .mode = @intCast(st.mode), .uid = st.uid, .nlink = @intCast(st.nlink) };
}

pub fn fchmod(fd: fd_t, mode: mode_t) Error!void {
    try check(if (libc) c.fchmod(fd, mode) else linux.fchmod(fd, mode));
}

pub fn mkdirat(dir: fd_t, path: []const u8, mode: mode_t) Error!void {
    const z = try posix.toPosixPath(path);
    try check(if (libc) c.mkdirat(dir, &z, mode) else linux.mkdirat(dir, &z, mode));
}

/// A pipe whose descriptors carry `flags` (`CLOEXEC`, `NONBLOCK`). Where the
/// system has no `pipe2` the flags are applied after creation.
pub fn pipe2(flags: posix.O) Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (builtin.os.tag.isDarwin()) {
        try check(c.pipe(&fds));
        errdefer for (fds) |fd| close(fd);
        for (fds) |fd| {
            if (flags.CLOEXEC) _ = try fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
            if (flags.NONBLOCK) {
                const current = try fcntl(fd, posix.F.GETFL, 0);
                _ = try fcntl(fd, posix.F.SETFL, current | @as(usize, @as(u32, @bitCast(posix.O{ .NONBLOCK = true }))));
            }
        }
        return fds;
    }
    if (libc) try check(c.pipe2(&fds, flags)) else try check(linux.pipe2(&fds, flags));
    return fds;
}

pub const WaitPidResult = struct { pid: pid_t, status: u32 };

/// Waits for a child; with `W.NOHANG` the result's pid is 0 while it runs.
pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
    var status: if (libc) c_int else i32 = 0;
    while (true) {
        const rc = if (libc) c.waitpid(pid, &status, @intCast(flags)) else linux.waitpid(pid, &status, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .pid = @intCast(rc), .status = @bitCast(status) },
            .INTR => continue,
            .CHILD => return .{ .pid = pid, .status = 0 },
            else => unreachable,
        }
    }
}

/// Forks the process; 0 in the child.
pub fn fork() Error!pid_t {
    const rc = if (libc) c.fork() else linux.fork();
    try check(rc);
    return @intCast(rc);
}

/// Writes some of `bytes`, retrying when a signal interrupts the call.
pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    const rc = if (libc) retrying(c.write, .{ fd, bytes.ptr, bytes.len }) else retrying(linux.write, .{ fd, bytes.ptr, bytes.len });
    try check(rc);
    return @intCast(rc);
}

pub fn flock(fd: fd_t, operation: i32) Error!void {
    while (true) {
        const rc = if (libc) c.flock(fd, operation) else linux.flock(fd, operation);
        if (posix.errno(rc) == .INTR) continue;
        return check(rc);
    }
}

pub fn geteuid() posix.uid_t {
    return if (libc) c.geteuid() else linux.geteuid();
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) Error!fd_t {
    const rc = if (libc) c.socket(domain, socket_type, protocol) else linux.socket(domain, socket_type, protocol);
    try check(rc);
    return @intCast(rc);
}

pub fn bind(fd: fd_t, address: *const posix.sockaddr, length: posix.socklen_t) Error!void {
    try check(if (libc) c.bind(fd, address, length) else linux.bind(fd, address, length));
}

pub fn listen(fd: fd_t, backlog: u31) Error!void {
    try check(if (libc) c.listen(fd, backlog) else linux.listen(fd, backlog));
}

/// Accepts a connection, applying `flags` (`SOCK.CLOEXEC`, `SOCK.NONBLOCK`).
pub fn accept(fd: fd_t, flags: u32) Error!fd_t {
    const rc = if (libc) retrying(c.accept4, .{ fd, null, null, flags }) else retrying(linux.accept4, .{ fd, null, null, flags });
    try check(rc);
    return @intCast(rc);
}

pub fn connect(fd: fd_t, address: *const posix.sockaddr, length: posix.socklen_t) Error!void {
    try check(if (libc) retrying(c.connect, .{ fd, address, length }) else retrying(linux.connect, .{ fd, address, length }));
}

pub fn send(fd: fd_t, bytes: []const u8, flags: u32) Error!usize {
    const rc = if (libc) retrying(c.send, .{ fd, bytes.ptr, bytes.len, flags }) else retrying(linux.sendto, .{ fd, bytes.ptr, bytes.len, flags, null, 0 });
    try check(rc);
    return @intCast(rc);
}

/// Moves a descriptor's file position to `offset` from the start.
pub fn seekTo(fd: fd_t, offset: u64) Error!void {
    if (builtin.os.tag == .windows) {
        if (kernel32.SetFilePointerEx(fd, @intCast(offset), null, 0) == 0) return error.Unexpected;
        return;
    }
    if (libc) {
        try check(c.lseek(fd, @intCast(offset), c.SEEK.SET));
    } else {
        try check(linux.lseek(fd, @intCast(offset), linux.SEEK.SET));
    }
}

/// A descriptor's file position.
pub fn position(fd: fd_t) Error!u64 {
    if (builtin.os.tag == .windows) {
        var at: i64 = 0;
        if (kernel32.SetFilePointerEx(fd, 0, &at, 1) == 0) return error.Unexpected;
        return @intCast(at);
    }
    const rc = if (libc) c.lseek(fd, 0, c.SEEK.CUR) else linux.lseek(fd, 0, linux.SEEK.CUR);
    try check(rc);
    return @intCast(rc);
}

const kernel32 = struct {
    extern "kernel32" fn SetFilePointerEx(file: std.os.windows.HANDLE, distance: i64, new_position: ?*i64, method: u32) callconv(.winapi) c_int;
};

pub const ShutdownHow = enum { recv, send, both };

pub fn shutdown(fd: fd_t, how: ShutdownHow) Error!void {
    const value: i32 = switch (how) {
        .recv => posix.SHUT.RD,
        .send => posix.SHUT.WR,
        .both => posix.SHUT.RDWR,
    };
    try check(if (libc) c.shutdown(fd, value) else linux.shutdown(fd, value));
}

pub fn open(path: []const u8, flags: posix.O, mode: mode_t) Error!fd_t {
    const z = try posix.toPosixPath(path);
    const rc = if (libc) retrying(c.openat, .{ posix.AT.FDCWD, &z, flags, mode }) else retrying(linux.openat, .{ posix.AT.FDCWD, &z, flags, mode });
    try check(rc);
    return @intCast(rc);
}

pub fn openat(dir: fd_t, path: []const u8, flags: posix.O, mode: mode_t) Error!fd_t {
    const z = try posix.toPosixPath(path);
    const rc = if (libc) retrying(c.openat, .{ dir, &z, flags, mode }) else retrying(linux.openat, .{ dir, &z, flags, mode });
    try check(rc);
    return @intCast(rc);
}

pub fn mkdir(path: []const u8, mode: mode_t) Error!void {
    const z = try posix.toPosixPath(path);
    try check(if (libc) c.mkdirat(posix.AT.FDCWD, &z, mode) else linux.mkdirat(posix.AT.FDCWD, &z, mode));
}

pub fn symlink(target: []const u8, link: []const u8) Error!void {
    const target_z = try posix.toPosixPath(target);
    const link_z = try posix.toPosixPath(link);
    try check(if (libc) c.symlinkat(&target_z, posix.AT.FDCWD, &link_z) else linux.symlinkat(&target_z, posix.AT.FDCWD, &link_z));
}

pub fn linkat(old_dir: fd_t, old_path: []const u8, new_dir: fd_t, new_path: []const u8, flags: u32) Error!void {
    const old_z = try posix.toPosixPath(old_path);
    const new_z = try posix.toPosixPath(new_path);
    try check(if (libc) c.linkat(old_dir, &old_z, new_dir, &new_z, flags) else linux.linkat(old_dir, &old_z, new_dir, &new_z, flags));
}
