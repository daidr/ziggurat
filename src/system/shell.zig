const std = @import("std");
const builtin = @import("builtin");
const win = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("shellapi.h");
}) else struct {};

pub const max_arguments = 128;
pub const max_argument_bytes = 16 * 1024;
pub const max_command_units = 32767;
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const LaunchOptions = struct {
    /// Absolute executable path. Windows requires an explicit .exe extension;
    /// no PATH/PATHEXT search, file association or command interpreter is used.
    executable: []const u8,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cancellation: ?*const Cancellation = null,
};
pub const Term = union(enum) { Exited: u32, Signal: u32, Stopped: u32, Unknown: u32 };
pub const NativeFailure = struct { domain: enum { win32, hresult }, code: u32 };
pub const IconOptions = struct {
    /// Native small/large shell icon only. No thumbnail or image-file decode.
    size: u16 = 32,
    background: u32 = 0xffffff,
    cancellation: ?*const Cancellation = null,
};
pub const FileIcon = struct {
    width: u16,
    height: u16,
    stride: usize,
    /// Caller-owned destination, top-down RGBA8. Alpha is always 255: native
    /// icon transparency was composited against IconOptions.background.
    pixels: []const u8,
};
pub const capabilities = .{
    .launch_executable = builtin.os.tag == .windows or builtin.os.tag == .linux,
    .open_url = false,
    .open_path = false,
    .reveal = false,
    .trash = false,
    .file_icon = builtin.os.tag == .windows,
    .installed_applications = false,
    .launch_application = false,
};

/// Standalone blocking system work on a caller-created worker. It never owns a
/// Window/App, starts a thread, posts a task or invokes an application callback.
/// Keep one owner; do not copy it after init. Call deinit on the same worker.
pub const Worker = struct {
    thread: std.Thread.Id,
    closed: bool = false,
    last_failure: ?NativeFailure = null,
    apartment: bool = false,

    pub fn init(main_thread: std.Thread.Id) !Worker {
        const thread = std.Thread.getCurrentId();
        if (thread == main_thread) return error.UiThreadForbidden;
        if (!capabilities.launch_executable) return error.UnsupportedCapability;
        return .{ .thread = thread };
    }
    pub fn deinit(self: *Worker) void {
        std.debug.assert(self.thread == std.Thread.getCurrentId());
        if (self.closed) return;
        if (builtin.os.tag == .windows and self.apartment) win.CoUninitialize();
        self.apartment = false;
        self.closed = true;
    }
    fn require(self: *Worker) !void {
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closed) return error.Closed;
        self.last_failure = null;
    }
    fn ensureApartment(self: *Worker) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (self.apartment) return;
        const result = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED);
        if (result < 0) {
            self.last_failure = .{ .domain = .hresult, .code = @bitCast(result) };
            return error.ComInitializationFailed;
        }
        self.apartment = true;
    }
    /// Blocking read-only icon lookup on this worker. All HICON/HBITMAP/DC
    /// resources are released before return. Pixels publish only on success.
    pub fn fileIcon(self: *Worker, path: []const u8, options: IconOptions, destination: []u8) !FileIcon {
        try self.require();
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (options.cancellation) |cancel| try cancel.check();
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        if ((options.size != 16 and options.size != 32) or options.background > 0xffffff) return error.InvalidIconOptions;
        const bytes = @as(usize, options.size) * options.size * 4;
        if (destination.len < bytes) return error.ResultCapacityExceeded;
        try self.ensureApartment();
        var storage: [max_argument_bytes + 1]u16 = undefined;
        const terminated = try wideZ(&storage, path);
        var info = std.mem.zeroes(win.SHFILEINFOW);
        const flags: win.UINT = @as(win.UINT, @intCast(win.SHGFI_ICON)) | @as(win.UINT, @intCast(if (options.size == 16) win.SHGFI_SMALLICON else win.SHGFI_LARGEICON));
        if (win.SHGetFileInfoW(terminated.ptr, 0, &info, @sizeOf(win.SHFILEINFOW), flags) == 0) {
            return error.IconLookupFailed;
        }
        defer _ = win.DestroyIcon(info.hIcon);
        if (options.cancellation) |cancel| try cancel.check();
        const dc = win.CreateCompatibleDC(null) orelse return error.IconRasterFailed;
        defer _ = win.DeleteDC(dc);
        var bitmap = std.mem.zeroes(win.BITMAPINFO);
        bitmap.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
        bitmap.bmiHeader.biWidth = options.size;
        bitmap.bmiHeader.biHeight = -@as(win.LONG, options.size);
        bitmap.bmiHeader.biPlanes = 1;
        bitmap.bmiHeader.biBitCount = 32;
        bitmap.bmiHeader.biCompression = win.BI_RGB;
        var bits: ?*anyopaque = null;
        const image = win.CreateDIBSection(dc, &bitmap, win.DIB_RGB_COLORS, &bits, null, 0) orelse return error.IconRasterFailed;
        defer _ = win.DeleteObject(image);
        const previous = win.SelectObject(dc, image) orelse return error.IconRasterFailed;
        defer _ = win.SelectObject(dc, previous);
        const pixels: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memset(pixels[0 .. bytes / 4], options.background);
        if (win.DrawIconEx(dc, 0, 0, info.hIcon, options.size, options.size, 0, null, win.DI_NORMAL) == 0) return error.IconRasterFailed;
        // Flush this thread's GDI batch before reading its DIB memory.
        if (win.GdiFlush() == 0) return error.IconRasterFailed;
        if (options.cancellation) |cancel| try cancel.check();
        for (pixels[0 .. bytes / 4], 0..) |pixel, index| {
            destination[index * 4] = @truncate(pixel >> 16);
            destination[index * 4 + 1] = @truncate(pixel >> 8);
            destination[index * 4 + 2] = @truncate(pixel);
            destination[index * 4 + 3] = 255;
        }
        return .{ .width = options.size, .height = options.size, .stride = @as(usize, options.size) * 4, .pixels = destination[0..bytes] };
    }
    /// Returns an owned child. The caller must wait or terminateAndWait on this
    /// worker, even if posting its result to the UI fails or the App has closed.
    /// Arguments/cwd are borrowed only until return. No child stream is piped.
    pub fn launchExecutable(self: *Worker, allocator: std.mem.Allocator, options: LaunchOptions) !Child {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateLaunch(options);
        if (builtin.os.tag == .windows) {
            var executable: [max_argument_bytes + 1]u16 = undefined;
            const exe = try wideZ(&executable, options.executable);
            var cwd: [max_argument_bytes + 1]u16 = undefined;
            const directory = if (options.cwd) |path| (try wideZ(&cwd, path)).ptr else null;
            var command: [max_command_units + 1]u16 = undefined;
            const line = try commandLine(&command, options);
            if (options.cancellation) |cancel| try cancel.check();
            var startup = std.mem.zeroes(win.STARTUPINFOW);
            startup.cb = @sizeOf(win.STARTUPINFOW);
            var info: win.PROCESS_INFORMATION = undefined;
            if (win.CreateProcessW(exe.ptr, line.ptr, null, null, 0, win.CREATE_NO_WINDOW, null, directory, &startup, &info) == 0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessLaunchFailed;
            }
            _ = win.CloseHandle(info.hThread);
            return .{ .thread = self.thread, .native = info.hProcess };
        } else if (builtin.os.tag == .linux) {
            var argv: [max_arguments + 1][]const u8 = undefined;
            argv[0] = options.executable;
            @memcpy(argv[1..][0..options.arguments.len], options.arguments);
            var child = std.process.Child.init(argv[0 .. options.arguments.len + 1], allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.cwd = options.cwd;
            if (options.cancellation) |cancel| try cancel.check();
            try child.spawn();
            child.waitForSpawn() catch |err| {
                // The exec-error handshake has consumed its pipe. Reap the
                // failed child here rather than returning an unowned zombie.
                _ = std.posix.waitpid(child.id, 0);
                return err;
            };
            child.argv = &.{};
            child.cwd = null;
            return .{ .thread = self.thread, .native = child };
        } else return error.UnsupportedCapability;
    }
};

/// One owned process, bound to its creating worker. Do not copy it. wait and
/// terminateAndWait close/reap exactly once; later calls return the saved term.
pub const Child = struct {
    thread: std.Thread.Id,
    native: if (builtin.os.tag == .windows) win.HANDLE else if (builtin.os.tag == .linux) std.process.Child else void,
    term: ?Term = null,
    last_failure: ?NativeFailure = null,
    fn require(self: *Child) !void {
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
    }
    pub fn wait(self: *Child) !Term {
        try self.require();
        if (self.term) |term| return term;
        if (builtin.os.tag == .windows) {
            if (win.WaitForSingleObject(self.native, win.INFINITE) != win.WAIT_OBJECT_0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessWaitFailed;
            }
            var code: win.DWORD = 0;
            if (win.GetExitCodeProcess(self.native, &code) == 0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessWaitFailed;
            }
            _ = win.CloseHandle(self.native);
            self.native = null;
            self.term = .{ .Exited = code };
        } else if (builtin.os.tag == .linux) self.term = switch (try self.native.wait()) {
            inline else => |value, tag| @unionInit(Term, @tagName(tag), value),
        } else return error.UnsupportedCapability;
        return self.term.?;
    }
    pub fn terminateAndWait(self: *Child) !Term {
        try self.require();
        if (self.term) |term| return term;
        if (builtin.os.tag == .windows) {
            if (win.TerminateProcess(self.native, 1) == 0) {
                const code = win.GetLastError();
                if (win.WaitForSingleObject(self.native, 0) != win.WAIT_OBJECT_0) {
                    self.last_failure = .{ .domain = .win32, .code = code };
                    return error.ProcessTerminationFailed;
                }
            }
        } else if (builtin.os.tag == .linux) {
            std.posix.kill(self.native.id, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return err,
            };
        } else return error.UnsupportedCapability;
        return self.wait();
    }
};

fn validateText(value: []const u8) !void {
    if (value.len > max_argument_bytes) return error.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
}
fn absolute(path: []const u8) bool {
    if (builtin.os.tag != .windows) return path.len != 0 and path[0] == '/';
    const slash = struct {
        fn is(value: u8) bool {
            return value == '\\' or value == '/';
        }
    }.is;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and slash(path[2])) return true;
    // UNC paths require both server and share; device namespaces are not shell
    // executable paths. A single root slash remains drive-relative on Windows.
    if (path.len < 5 or !slash(path[0]) or !slash(path[1]) or path[2] == '?' or path[2] == '.') return false;
    var index: usize = 2;
    while (index < path.len and !slash(path[index])) : (index += 1) {}
    return index > 2 and index + 1 < path.len and !slash(path[index + 1]);
}
fn validateLaunch(options: LaunchOptions) !void {
    try validateText(options.executable);
    if (!absolute(options.executable)) return error.AbsolutePathRequired;
    if (builtin.os.tag == .windows and (!std.ascii.endsWithIgnoreCase(options.executable, ".exe") or std.mem.indexOfScalar(u8, options.executable, '"') != null)) return error.ExecutableRequired;
    if (options.arguments.len > max_arguments) return error.TooManyArguments;
    var bytes: usize = options.executable.len;
    for (options.arguments) |arg| {
        try validateText(arg);
        bytes += arg.len + 1;
        if (bytes > 64 * 1024) return error.CommandTooLong;
    }
    if (options.cwd) |cwd| {
        try validateText(cwd);
        if (!absolute(cwd)) return error.AbsolutePathRequired;
    }
}
fn wideZ(storage: []u16, text: []const u8) ![:0]u16 {
    const length = std.unicode.utf8ToUtf16Le(storage[0 .. storage.len - 1], text) catch return error.ArgumentTooLong;
    storage[length] = 0;
    return storage[0..length :0];
}
fn commandLine(storage: []u16, options: LaunchOptions) ![:0]u16 {
    var used: usize = 0;
    var argument: [max_argument_bytes]u16 = undefined;
    for (0..options.arguments.len + 1) |index| {
        if (index > 0) try unit(storage, &used, ' ');
        const text = if (index == 0) options.executable else options.arguments[index - 1];
        const length = std.unicode.utf8ToUtf16Le(&argument, text) catch return error.ArgumentTooLong;
        try unit(storage, &used, '"');
        var at: usize = 0;
        while (at < length) {
            var slashes: usize = 0;
            while (at < length and argument[at] == '\\') : (at += 1) slashes += 1;
            const quote = at < length and argument[at] == '"';
            const count = if (at == length or quote) slashes * 2 else slashes;
            for (0..count) |_| try unit(storage, &used, '\\');
            if (at == length) break;
            if (quote) try unit(storage, &used, '\\');
            try unit(storage, &used, argument[at]);
            at += 1;
        }
        try unit(storage, &used, '"');
    }
    storage[used] = 0;
    return storage[0..used :0];
}
fn unit(storage: []u16, used: *usize, value: u16) !void {
    if (used.* >= @min(max_command_units - 1, storage.len - 1)) return error.CommandTooLong;
    storage[used.*] = value;
    used.* += 1;
}

test "shell arguments are bounded UTF-8 paths and Windows quoting round trips" {
    const path = if (builtin.os.tag == .windows) "C:\\tools\\app.exe" else "/usr/bin/app";
    try validateLaunch(.{ .executable = path, .arguments = &.{ "", "a b", "中文🦎", "quote\"end", "slash\\", "\\\"", "$(literal);&" } });
    try std.testing.expectError(error.AbsolutePathRequired, validateLaunch(.{ .executable = "app.exe" }));
    try std.testing.expectError(error.EmbeddedNul, validateLaunch(.{ .executable = path, .arguments = &.{"a\x00b"} }));
    try std.testing.expectError(error.InvalidUtf8, validateLaunch(.{ .executable = path, .arguments = &.{"\xff"} }));
    const options: LaunchOptions = .{ .executable = path, .arguments = &.{ "", "a b", "中文🦎", "quote\"end", "slash\\", "\\\"", "$(literal);&" } };
    var buffer: [2048]u16 = undefined;
    const line = try commandLine(&buffer, options);
    var args = try std.process.ArgIteratorWindows.init(std.testing.allocator, line);
    defer args.deinit();
    try std.testing.expectEqualStrings(path, args.next().?);
    for (options.arguments) |arg| try std.testing.expectEqualStrings(arg, args.next().?);
    try std.testing.expect(args.next() == null);
    var cancellation: Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, cancellation.check());
    try std.testing.expectError(error.UiThreadForbidden, Worker.init(std.Thread.getCurrentId()));
}
