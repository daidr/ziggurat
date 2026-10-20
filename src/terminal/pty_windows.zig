//! A Windows pseudo console: the program runs attached to a console whose
//! input and output this process reaches through two pipes. Pseudo
//! consoles need Windows 10 1809 or later; on older systems spawning
//! returns `Unsupported`.
const std = @import("std");
const windows = std.os.windows;
const pty = @import("pty.zig");

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HRESULT = windows.HRESULT;
const HPCON = *anyopaque;
const COORD = extern struct { x: i16, y: i16 };

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const INFINITE: DWORD = 0xffffffff;
const WAIT_OBJECT_0: DWORD = 0;
const ERROR_BROKEN_PIPE: DWORD = 109;
const ERROR_NO_DATA: DWORD = 232;
const ERROR_OPERATION_ABORTED: DWORD = 995;

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, size: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, size: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attribute: usize, value: ?*anyopaque, size: usize, previous: ?*anyopaque, return_size: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(application: ?[*:0]const u16, command_line: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: BOOL, flags: DWORD, environment: ?*anyopaque, directory: ?[*:0]const u16, startup: *windows.STARTUPINFOW, information: *windows.PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: c_uint) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(block: [*]u16) callconv(.winapi) BOOL;

const CreatePseudoConsole = *const fn (COORD, HANDLE, HANDLE, DWORD, *HPCON) callconv(.winapi) HRESULT;
const ResizePseudoConsole = *const fn (HPCON, COORD) callconv(.winapi) HRESULT;
const ClosePseudoConsole = *const fn (HPCON) callconv(.winapi) void;

const Api = struct { create: CreatePseudoConsole, resize: ResizePseudoConsole, close: ClosePseudoConsole };

fn api() ?Api {
    const kernel = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll")) orelse return null;
    const create = GetProcAddress(kernel, "CreatePseudoConsole") orelse return null;
    const resize = GetProcAddress(kernel, "ResizePseudoConsole") orelse return null;
    const close = GetProcAddress(kernel, "ClosePseudoConsole") orelse return null;
    return .{ .create = @ptrCast(create), .resize = @ptrCast(resize), .close = @ptrCast(close) };
}

fn coord(size: pty.Size) COORD {
    return .{ .x = @intCast(@min(@max(size.cols, 1), std.math.maxInt(i16))), .y = @intCast(@min(@max(size.rows, 1), std.math.maxInt(i16))) };
}

pub const Pty = struct {
    console: ?HPCON,
    calls: Api,
    /// Writes reach the program's input.
    input: HANDLE,
    /// Reads take the console's output.
    output: HANDLE,
    process: HANDLE,
    pid: DWORD,
    console_mutex: std.Thread.Mutex = .{},

    pub fn spawn(allocator: std.mem.Allocator, command: pty.Command) pty.Error!Pty {
        const calls = api() orelse return error.Unsupported;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const line = try commandLine(arena, command.argv);
        const env = try environment(arena, command.env);
        const cwd = if (command.cwd) |dir| std.unicode.wtf8ToWtf16LeAllocZ(arena, dir) catch return error.InvalidCommand else null;

        var input_read: HANDLE = undefined;
        var input_write: HANDLE = undefined;
        if (CreatePipe(&input_read, &input_write, null, 0) == 0) return error.SystemResources;
        defer _ = CloseHandle(input_read);
        errdefer _ = CloseHandle(input_write);
        var output_read: HANDLE = undefined;
        var output_write: HANDLE = undefined;
        if (CreatePipe(&output_read, &output_write, null, 0) == 0) return error.SystemResources;
        defer _ = CloseHandle(output_write);
        errdefer _ = CloseHandle(output_read);

        var console: HPCON = undefined;
        if (calls.create(coord(command.size), input_read, output_write, 0, &console) < 0) return error.SpawnFailed;
        errdefer calls.close(console);

        var list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &list_size);
        const list = arena.alignedAlloc(u8, .of(usize), list_size) catch return error.OutOfMemory;
        if (InitializeProcThreadAttributeList(list.ptr, 1, 0, &list_size) == 0) return error.SystemResources;
        defer DeleteProcThreadAttributeList(list.ptr);
        if (UpdateProcThreadAttribute(list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, @sizeOf(HPCON), null, null) == 0) return error.SystemResources;

        var startup: STARTUPINFOEXW = .{ .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW), .lpAttributeList = list.ptr };
        startup.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        // Without this the program could inherit this process's redirected
        // standard handles instead of the console's.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        var information: windows.PROCESS_INFORMATION = undefined;
        const flags = EXTENDED_STARTUPINFO_PRESENT | (if (env != null) CREATE_UNICODE_ENVIRONMENT else 0);
        if (CreateProcessW(null, line, null, null, 0, flags, if (env) |block| @ptrCast(block.ptr) else null, if (cwd) |dir| dir.ptr else null, &startup.StartupInfo, &information) == 0) return error.SpawnFailed;
        _ = CloseHandle(information.hThread);
        return .{ .console = console, .calls = calls, .input = input_write, .output = output_read, .process = information.hProcess, .pid = information.dwProcessId };
    }

    /// Blocks until output arrives; 0 once the console closed.
    pub fn read(self: *const Pty, buffer: []u8) !usize {
        var count: DWORD = 0;
        if (ReadFile(self.output, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(DWORD))), &count, null) == 0) {
            return switch (GetLastError()) {
                ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_OPERATION_ABORTED => 0,
                else => error.InputOutput,
            };
        }
        return count;
    }

    /// Blocks until the console takes the bytes.
    pub fn write(self: *const Pty, bytes: []const u8) !usize {
        var count: DWORD = 0;
        if (WriteFile(self.input, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(DWORD))), &count, null) == 0) return error.BrokenPipe;
        return count;
    }

    pub fn resize(self: *Pty, size: pty.Size) void {
        self.console_mutex.lock();
        defer self.console_mutex.unlock();
        const console = self.console orelse return;
        _ = self.calls.resize(console, coord(size));
    }

    pub fn terminate(self: *const Pty) void {
        _ = TerminateProcess(self.process, 1);
    }

    /// The exit once the program ended, waiting for it when `block`.
    pub fn wait(self: *const Pty, block: bool) ?pty.Exit {
        if (WaitForSingleObject(self.process, if (block) INFINITE else 0) != WAIT_OBJECT_0) return null;
        var code: DWORD = 0;
        _ = GetExitCodeProcess(self.process, &code);
        return .{ .code = code };
    }

    /// Close the console, which ends its output once read. It may wait for
    /// a reader to drain that output, so call it from a worker.
    pub fn closeConsole(self: *Pty) void {
        self.console_mutex.lock();
        const console = self.console;
        self.console = null;
        self.console_mutex.unlock();
        if (console) |value| self.calls.close(value);
    }

    pub fn close(self: *Pty) void {
        self.closeConsole();
        _ = CloseHandle(self.input);
        _ = CloseHandle(self.output);
        _ = CloseHandle(self.process);
    }
};

/// Arguments quoted the way the C runtime splits them back.
fn commandLine(arena: std.mem.Allocator, argv: []const []const u8) ![*:0]u16 {
    var text: std.ArrayList(u8) = .empty;
    if (argv.len == 0) {
        const comspec = std.process.getEnvVarOwned(arena, "COMSPEC") catch try arena.dupe(u8, "cmd.exe");
        try text.appendSlice(arena, comspec);
    }
    for (argv, 0..) |arg, i| {
        if (i > 0) try text.append(arena, ' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) {
            try text.appendSlice(arena, arg);
            continue;
        }
        try text.append(arena, '"');
        var backslashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                backslashes += 1;
                continue;
            }
            const doubled = if (byte == '"') backslashes * 2 + 1 else backslashes;
            try text.appendNTimes(arena, '\\', doubled);
            backslashes = 0;
            try text.append(arena, byte);
        }
        try text.appendNTimes(arena, '\\', backslashes * 2);
        try text.append(arena, '"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, text.items) catch error.InvalidCommand;
}

/// This process's environment block with `variables` set, or null to
/// inherit it unchanged.
fn environment(arena: std.mem.Allocator, variables: []const pty.Variable) !?[]u16 {
    if (variables.len == 0) return null;
    var block: std.ArrayList(u16) = .empty;
    const current = GetEnvironmentStringsW() orelse return error.SystemResources;
    defer _ = FreeEnvironmentStringsW(current);
    var at: usize = 0;
    while (current[at] != 0) {
        const entry = std.mem.span(@as([*:0]const u16, @ptrCast(current + at)));
        at += entry.len + 1;
        const name_end = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse entry.len;
        var keep = true;
        for (variables) |variable| {
            const name = std.unicode.wtf8ToWtf16LeAlloc(arena, variable.name) catch return error.InvalidCommand;
            if (std.os.windows.eqlIgnoreCaseWTF16(name, entry[0..name_end])) keep = false;
        }
        if (!keep) continue;
        try block.appendSlice(arena, entry);
        try block.append(arena, 0);
    }
    for (variables) |variable| {
        if (variable.name.len == 0 or std.mem.indexOfScalar(u8, variable.name, '=') != null) return error.InvalidCommand;
        const pair = std.fmt.allocPrint(arena, "{s}={s}", .{ variable.name, variable.value }) catch return error.OutOfMemory;
        const wide = std.unicode.wtf8ToWtf16LeAlloc(arena, pair) catch return error.InvalidCommand;
        try block.appendSlice(arena, wide);
        try block.append(arena, 0);
    }
    try block.append(arena, 0);
    return block.items;
}
