//! The CLI's own output, on standard error: a line per step. On a
//! terminal the step in progress shows a spinner, how long it has run and
//! what it is doing, and its line then says how it went. Elsewhere each
//! step prints when it starts and when it ends. NO_COLOR turns colors off;
//! FORCE_COLOR turns them on where the output is not a terminal.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const Symbols = struct {
    ok: []const u8,
    fail: []const u8,
    warn: []const u8,
    info: []const u8,
    start: []const u8,
    ellipsis: []const u8,
    spinner: []const []const u8,
};

pub const unicode_symbols: Symbols = .{ .ok = "✓", .fail = "✗", .warn = "▲", .info = "•", .start = "○", .ellipsis = "…", .spinner = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" } };
/// For consoles whose fonts lack the others, as the Windows console's may.
pub const plain_symbols: Symbols = .{ .ok = "√", .fail = "×", .warn = "!", .info = "i", .start = "o", .ellipsis = "...", .spinner = &.{ "-", "\\", "|", "/" } };

pub const Mode = struct {
    /// The spinner's line is redrawn in place.
    live: bool,
    color: bool,
    symbols: *const Symbols,
};

/// How to write to an output that is (`terminal`) or is not a terminal,
/// given the environment.
pub fn decide(terminal: bool, environment: *const std.process.Environ.Map) Mode {
    const term = environment.get("TERM") orelse "";
    const live = terminal and !std.mem.eql(u8, term, "dumb");
    const force = environment.get("FORCE_COLOR") orelse "";
    const forced = force.len > 0 and !std.mem.eql(u8, force, "0") and !std.mem.eql(u8, force, "false");
    const no_color = if (environment.get("NO_COLOR")) |value| value.len > 0 else false;
    return .{ .live = live, .color = !no_color and (live or forced), .symbols = if (unicodeTerminal(environment)) &unicode_symbols else &plain_symbols };
}

fn unicodeTerminal(environment: *const std.process.Environ.Map) bool {
    const term = environment.get("TERM") orelse "";
    // The Linux virtual console's font has none of them.
    if (builtin.os.tag != .windows) return !std.mem.eql(u8, term, "linux");
    // The Windows console's fonts lack them; the terminals that replace it do not.
    return environment.get("WT_SESSION") != null or environment.get("CI") != null or
        std.mem.eql(u8, environment.get("TERM_PROGRAM") orelse "", "vscode") or
        std.mem.eql(u8, term, "xterm-256color") or std.mem.eql(u8, term, "alacritty");
}

pub const Console = struct {
    file: std.Io.File,
    mode: Mode,
    mutex: zio.Mutex = .{},
    /// The step in progress, which the spinner shows.
    task: ?*Task = null,
    drawn: bool = false,
    frame: usize = 0,
    spinner: ?std.Thread = null,
    stopping: bool = false,

    /// A console on standard error.
    pub fn stderr(environment: *const std.process.Environ.Map) Console {
        const file = std.Io.File.stderr();
        var terminal = file.isTty(zio.io()) catch false;
        if (terminal and builtin.os.tag == .windows) terminal = if (file.enableAnsiEscapeCodes(zio.io())) true else |_| false;
        return .{ .file = file, .mode = decide(terminal, environment) };
    }

    /// Stops the spinner. Call before exiting.
    pub fn deinit(self: *Console) void {
        self.mutex.lock();
        self.stopping = true;
        const thread = self.spinner;
        self.spinner = null;
        self.mutex.unlock();
        if (thread) |t| t.join();
    }

    pub fn style(self: *const Console, writer: *std.Io.Writer, sgr: []const u8, text: []const u8) !void {
        if (!self.mode.color or text.len == 0) return writer.writeAll(text);
        try writer.print("\x1b[{s}m{s}\x1b[0m", .{ sgr, text });
    }

    /// Says what a command does, or did.
    pub fn log(self: *Console, comptime format: []const u8, arguments: anytype) void {
        self.note("2", self.mode.symbols.info, format, arguments);
    }

    /// Says what a command did not do, or what may be wrong.
    pub fn warn(self: *Console, comptime format: []const u8, arguments: anytype) void {
        self.note("33", self.mode.symbols.warn, format, arguments);
    }

    /// Says what failed, as an error of a file a command reads.
    pub fn problem(self: *Console, comptime format: []const u8, arguments: anytype) void {
        self.note("31", self.mode.symbols.fail, format, arguments);
    }

    /// The error that ends the command.
    pub fn fatal(self: *Console, comptime format: []const u8, arguments: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clear();
        var buffer: [4096]u8 = undefined;
        var out = self.file.writerStreaming(zio.io(), &buffer);
        const writer = &out.interface;
        writer.writeAll("\n  ") catch {};
        self.style(writer, "1;31", "error:") catch {};
        writer.writeByte(' ') catch {};
        writer.print(format ++ "\n", arguments) catch {};
        writer.flush() catch {};
    }

    fn note(self: *Console, sgr: []const u8, symbol: []const u8, comptime format: []const u8, arguments: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clear();
        var buffer: [4096]u8 = undefined;
        var out = self.file.writerStreaming(zio.io(), &buffer);
        const writer = &out.interface;
        writer.writeAll("  ") catch {};
        self.style(writer, sgr, symbol) catch {};
        writer.writeByte(' ') catch {};
        // Lines after the first are indented under it.
        var text: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&text, format, arguments) catch &text;
        var lines = std.mem.splitScalar(u8, message, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) writer.writeAll("    ") catch {};
            writer.writeAll(line) catch {};
            writer.writeByte('\n') catch {};
            first = false;
        }
        writer.flush() catch {};
        self.draw();
    }

    /// Starts a step, which `task` tracks until done or failed. `task`
    /// must stay in place until then.
    pub fn start(self: *Console, task: *Task, title: []const u8) void {
        task.* = .{ .console = self, .started = zio.nanoTimestamp() };
        task.title_len = copy(&task.title, title);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clear();
        if (!self.mode.live) {
            var buffer: [512]u8 = undefined;
            var out = self.file.writerStreaming(zio.io(), &buffer);
            out.interface.writeAll("  ") catch {};
            self.style(&out.interface, "2", self.mode.symbols.start) catch {};
            out.interface.print(" {s}\n", .{task.titleText()}) catch {};
            out.interface.flush() catch {};
        }
        self.task = task;
        self.draw();
        if (self.mode.live and self.spinner == null and !self.stopping) {
            self.spinner = std.Thread.spawn(.{}, spin, .{self}) catch null;
        }
    }

    fn spin(self: *Console) void {
        while (true) {
            zio.sleep(80 * std.time.ns_per_ms);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return;
            self.frame +%= 1;
            self.draw();
        }
    }

    /// Draws the spinner's line. With the mutex held.
    fn draw(self: *Console) void {
        if (!self.mode.live) return;
        const task = self.task orelse return;
        var buffer: [1024]u8 = undefined;
        var out = self.file.writerStreaming(zio.io(), &buffer);
        const writer = &out.interface;
        const room = terminalWidth(self.file) -| 5;
        const symbols = self.mode.symbols;
        const title = fit(task.titleText(), room, symbols.ellipsis);
        var left = room -| codePoints(title.text) -| @as(usize, if (title.cut) codePoints(symbols.ellipsis) else 0);
        var elapsed_buffer: [16]u8 = undefined;
        const seconds = @divTrunc(zio.nanoTimestamp() - task.started, std.time.ns_per_s);
        var elapsed: []const u8 = if (seconds >= 1) formatElapsed(&elapsed_buffer, @intCast(seconds)) else "";
        if (elapsed.len + 1 > left) elapsed = "";
        left -|= elapsed.len + 1;
        // Without wrapping, so a long line cannot scroll the screen.
        writer.writeAll("\x1b[?7l\r  ") catch {};
        self.style(writer, "36", symbols.spinner[self.frame % symbols.spinner.len]) catch {};
        writer.writeByte(' ') catch {};
        title.write(writer, symbols.ellipsis) catch {};
        if (elapsed.len > 0) {
            writer.writeByte(' ') catch {};
            self.style(writer, "2", elapsed) catch {};
        }
        const detail = task.detail[0..task.detail_len];
        if (detail.len > 0 and left > 8) {
            writer.writeAll("  ") catch {};
            if (self.mode.color) writer.writeAll("\x1b[2m") catch {};
            fit(detail, left - 2, symbols.ellipsis).write(writer, symbols.ellipsis) catch {};
            if (self.mode.color) writer.writeAll("\x1b[0m") catch {};
        }
        writer.writeAll("\x1b[K\x1b[?7h") catch {};
        writer.flush() catch {};
        self.drawn = true;
    }

    /// Erases the spinner's line. With the mutex held.
    fn clear(self: *Console) void {
        if (!self.drawn) return;
        self.file.writeStreamingAll(zio.io(), "\r\x1b[K") catch {};
        self.drawn = false;
    }
};

pub const Task = struct {
    console: *Console,
    started: i128,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    detail: [128]u8 = undefined,
    detail_len: usize = 0,

    fn titleText(self: *const Task) []const u8 {
        return self.title[0..self.title_len];
    }

    /// What the step is doing, shown after its title on a terminal.
    pub fn set(self: *Task, comptime format: []const u8, arguments: anytype) void {
        const console = self.console;
        console.mutex.lock();
        defer console.mutex.unlock();
        self.detail_len = (std.fmt.bufPrint(&self.detail, format, arguments) catch @as([]const u8, "")).len;
    }

    pub fn done(self: *Task, comptime format: []const u8, arguments: anytype) void {
        var text: [512]u8 = undefined;
        self.finish(true, std.fmt.bufPrint(&text, format, arguments) catch self.titleText());
    }

    pub fn fail(self: *Task) void {
        self.finish(false, self.titleText());
    }

    fn finish(self: *Task, ok: bool, message: []const u8) void {
        const console = self.console;
        console.mutex.lock();
        defer console.mutex.unlock();
        if (console.task == self) console.task = null;
        console.clear();
        var buffer: [1024]u8 = undefined;
        var out = console.file.writerStreaming(zio.io(), &buffer);
        const writer = &out.interface;
        writer.writeAll("  ") catch {};
        if (ok) console.style(writer, "32", console.mode.symbols.ok) catch {} else console.style(writer, "31", console.mode.symbols.fail) catch {};
        writer.print(" {s}  ", .{message}) catch {};
        var duration: [16]u8 = undefined;
        const elapsed: u64 = @intCast(@max(zio.nanoTimestamp() - self.started, 0));
        console.style(writer, "2", formatDuration(&duration, elapsed)) catch {};
        writer.writeByte('\n') catch {};
        writer.flush() catch {};
    }
};

fn copy(buffer: []u8, text: []const u8) usize {
    var length = @min(buffer.len, text.len);
    // Not inside a UTF-8 sequence.
    while (length > 0 and length < text.len and text[length] & 0xc0 == 0x80) length -= 1;
    @memcpy(buffer[0..length], text[0..length]);
    return length;
}

fn codePoints(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub const Fit = struct {
    text: []const u8,
    /// Ends with the ellipsis.
    cut: bool,

    fn write(self: Fit, writer: *std.Io.Writer, ellipsis: []const u8) !void {
        try writer.writeAll(self.text);
        if (self.cut) try writer.writeAll(ellipsis);
    }
};

/// What of `text` fits in `room` code points with `ellipsis` after it.
pub fn fit(text: []const u8, room: usize, ellipsis: []const u8) Fit {
    if (codePoints(text) <= room) return .{ .text = text, .cut = false };
    const keep = room -| codePoints(ellipsis);
    const view = std.unicode.Utf8View.init(text) catch return .{ .text = text[0..@min(text.len, keep)], .cut = true };
    var iterator = view.iterator();
    for (0..keep) |_| _ = iterator.nextCodepointSlice();
    return .{ .text = text[0..iterator.i], .cut = true };
}

/// "120ms", "1.5s" or "2m 05s".
pub fn formatDuration(buffer: *[16]u8, nanoseconds: u64) []const u8 {
    if (nanoseconds < std.time.ns_per_s) return std.fmt.bufPrint(buffer, "{d}ms", .{nanoseconds / std.time.ns_per_ms}) catch unreachable;
    if (nanoseconds < std.time.ns_per_min) return std.fmt.bufPrint(buffer, "{d}.{d}s", .{ nanoseconds / std.time.ns_per_s, nanoseconds / (100 * std.time.ns_per_ms) % 10 }) catch unreachable;
    return formatElapsed(buffer, nanoseconds / std.time.ns_per_s);
}

/// "12s" or "2m 05s".
pub fn formatElapsed(buffer: *[16]u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 }) catch unreachable;
}

/// "4.2 MB" for a byte count.
pub fn formatSize(buffer: *[16]u8, bytes: u64) []const u8 {
    if (bytes < 1000) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch unreachable;
    if (bytes < 1000 * 1000) return std.fmt.bufPrint(buffer, "{d}.{d} kB", .{ bytes / 1000, bytes / 100 % 10 }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}.{d} MB", .{ bytes / 1000_000, bytes / 100_000 % 10 }) catch unreachable;
}

fn terminalWidth(file: std.Io.File) usize {
    if (builtin.os.tag == .linux or builtin.os.tag.isDarwin()) {
        var size: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) == 0 and size.col > 0) return size.col;
    }
    return 80;
}

test "colors follow NO_COLOR and FORCE_COLOR" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expect(decide(true, &environment).color);
    try std.testing.expect(!decide(false, &environment).color);
    try environment.put("FORCE_COLOR", "1");
    try std.testing.expect(decide(false, &environment).color);
    try std.testing.expect(!decide(false, &environment).live);
    try environment.put("NO_COLOR", "1");
    try std.testing.expect(!decide(true, &environment).color);
    try environment.put("TERM", "dumb");
    try std.testing.expect(!decide(true, &environment).live);
}

test "steps print a line each when the output is not a terminal" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(zio.io(), "out", .{ .read = true });
    defer file.close(zio.io());
    var console: Console = .{ .file = file, .mode = .{ .live = false, .color = false, .symbols = &plain_symbols } };
    defer console.deinit();
    var task: Task = undefined;
    console.start(&task, "Uploading feed.json");
    task.set("{d}%", .{50});
    task.done("Uploaded {s}", .{"feed.json"});
    console.warn("two\nlines", .{});
    console.start(&task, "Generating");
    task.fail();
    var buffer: [512]u8 = undefined;
    const text = buffer[0..try file.readPositionalAll(zio.io(), &buffer, 0)];
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("  o Uploading feed.json", lines.next().?);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "  √ Uploaded feed.json  "));
    try std.testing.expectEqualStrings("  ! two", lines.next().?);
    try std.testing.expectEqualStrings("    lines", lines.next().?);
    try std.testing.expectEqualStrings("  o Generating", lines.next().?);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "  × Generating  "));
}

test "durations, sizes and cut text" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("120ms", formatDuration(&buffer, 120 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("1.5s", formatDuration(&buffer, 1500 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("2m 05s", formatDuration(&buffer, 125 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("4.2 MB", formatSize(&buffer, 4_250_000));
    try std.testing.expect(!fit("héllo", 5, "…").cut);
    const cut = fit("héllo wörld", 4, "…");
    try std.testing.expect(cut.cut);
    try std.testing.expectEqualStrings("hél", cut.text);
}
