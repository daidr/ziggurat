const std = @import("std");
const builtin = @import("builtin");
const schemes = @import("schemes.zig");

pub const capacity = 4;
pub const origin_capacity = 8;
pub const OwnedOrigins = struct {
    allocator: std.mem.Allocator,
    origins: [][]const u8,
    pub fn init(allocator: std.mem.Allocator, input: []const []const u8) !OwnedOrigins {
        if (input.len == 0 or input.len > origin_capacity) return error.InvalidDownloadOrigins;
        const origins = try allocator.alloc([]const u8, input.len);
        errdefer allocator.free(origins);
        var count: usize = 0;
        errdefer for (origins[0..count]) |origin| allocator.free(origin);
        for (input, 0..) |origin, i| {
            if (!(std.ascii.startsWithIgnoreCase(origin, "https://") or std.ascii.startsWithIgnoreCase(origin, "http://"))) return error.InvalidDownloadOrigin;
            var canonical: [schemes.origin_limit]u8 = undefined;
            origins[i] = try allocator.dupe(u8, try schemes.canonicalOrigin(&canonical, origin, &.{}));
            count += 1;
            for (origins[0..i]) |previous| if (std.mem.eql(u8, previous, origins[i])) return error.DuplicateDownloadOrigin;
        }
        return .{ .allocator = allocator, .origins = origins };
    }
    pub fn deinit(self: OwnedOrigins) void {
        for (self.origins) |origin| self.allocator.free(origin);
        self.allocator.free(self.origins);
    }
};
pub const Limits = struct {
    max_active: u8 = capacity,
    /// Reject a known Content-Length above this value before accepting.
    max_known_bytes: u64 = 64 * 1024 * 1024,
    allow_unknown_length: bool = false,
    /// Cancel after a native progress event observes this threshold exceeded.
    /// This is not a hard disk/network quota; the Runtime may buffer ahead.
    max_received_bytes: u64 = 64 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_active == 0 or self.max_active > capacity or self.max_known_bytes == 0 or self.max_received_bytes == 0) return error.InvalidDownloadLimits;
    }
};
pub const TargetOptions = struct {
    /// Worker precheck only. Runtime opens by path, so this cannot provide an
    /// atomic no-replace guarantee. Use a trusted private parent directory.
    accept_overwrite: bool = false,
};
fn validOutputName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (builtin.os.tag != .windows) return true;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    for (name) |byte| if (byte < 32 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) return false;
    const stem = std.mem.trim(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |device| if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    if (stem.len >= 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt"))) {
        const number = stem[3..];
        if ((number.len == 1 and number[0] >= '1' and number[0] <= '9') or std.mem.eql(u8, number, "¹") or std.mem.eql(u8, number, "²") or std.mem.eql(u8, number, "³")) return false;
    }
    return true;
}
/// The file name to save a download as, from the page's or server's
/// untrusted suggestion: its last path component (either slash separates),
/// or "download" when nothing is left. On Windows, characters a file name
/// cannot hold become "_", trailing dots and spaces go, and a device name
/// gains a leading "_". The result lives in `buffer` (256 bytes suffice).
pub fn safeName(buffer: []u8, suggested: []const u8) []const u8 {
    var name = suggested;
    if (std.mem.lastIndexOfAny(u8, name, "/\\")) |slash| name = name[slash + 1 ..];
    if (builtin.os.tag == .windows) name = std.mem.trimRight(u8, name, ". ");
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) name = "download";
    var length: usize = 0;
    for (name) |byte| {
        if (length == buffer.len) break;
        buffer[length] = if (byte == 0 or (builtin.os.tag == .windows and (byte < 32 or std.mem.indexOfScalar(u8, "<>:\"|?*", byte) != null))) '_' else byte;
        length += 1;
    }
    length = utf8Cut(buffer[0..length], name.len);
    if (builtin.os.tag != .windows) return buffer[0..length];
    // A cut can leave a trailing dot or space, which Windows would drop.
    length = std.mem.trimRight(u8, buffer[0..length], ". ").len;
    if (length == 0) return buffer[0..0];
    // Only a device name is left invalid once the characters are replaced.
    if (!validOutputName(buffer[0..length])) {
        if (length == buffer.len) length = utf8Cut(buffer[0 .. length - 1], length);
        std.mem.copyBackwards(u8, buffer[1 .. length + 1], buffer[0..length]);
        buffer[0] = '_';
        length += 1;
    }
    return buffer[0..length];
}
/// The length of `bytes`, a prefix of a `whole` long UTF-8 text, without a
/// trailing partial sequence when the prefix is a cut.
fn utf8Cut(bytes: []const u8, whole: usize) usize {
    if (bytes.len == whole) return bytes.len;
    var length = bytes.len;
    while (length > 0 and bytes[length - 1] & 0xc0 == 0x80) length -= 1;
    if (length > 0 and bytes[length - 1] & 0x80 != 0) {
        const lead = bytes[length - 1];
        const size: usize = if (lead & 0xe0 == 0xc0) 2 else if (lead & 0xf0 == 0xe0) 3 else 4;
        if (bytes.len - (length - 1) < size) return length - 1;
    }
    return bytes.len;
}
/// Worker only: `directory/name`, numbered "name (2).ext", "name (3).ext"
/// and so on when a file already has the name, as browsers save downloads.
/// The caller owns the path. Another process can still take it before the
/// Runtime writes, so prepare the Destination without `accept_overwrite`.
pub fn uniquePath(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, directory: []const u8, name: []const u8) ![]u8 {
    if (std.Thread.getCurrentId() == process_main_thread_id) return error.UiThreadForbidden;
    if (!std.fs.path.isAbsolute(directory)) return error.AbsoluteOutputPathRequired;
    if (!validOutputName(name) or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidOutputName;
    var dir = try std.fs.openDirAbsolute(directory, .{});
    defer dir.close();
    const extension = std.fs.path.extension(name);
    const stem = name[0 .. name.len - extension.len];
    var number: u32 = 1;
    while (number <= 9999) : (number += 1) {
        const candidate = if (number == 1) try allocator.dupe(u8, name) else try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, number, extension });
        defer allocator.free(candidate);
        _ = dir.statFile(candidate) catch |err| switch (err) {
            error.FileNotFound => return std.fs.path.join(allocator, &.{ directory, candidate }),
            else => return err,
        };
    }
    return error.OutputAlreadyExists;
}
/// Owns two bounded allocations, no COM objects or borrowed handles. Do not copy;
/// successful native commit consumes it. deinit may run on the preparing worker
/// after App.post fails, and never deletes a completed/partial download.
pub const Destination = struct {
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    wide: ?[:0]const u16,
    accept_overwrite: bool,

    pub fn prepare(allocator: std.mem.Allocator, process_main_thread_id: std.Thread.Id, absolute_path: []const u8, options: TargetOptions) !Destination {
        if (std.Thread.getCurrentId() == process_main_thread_id) return error.UiThreadForbidden;
        if (absolute_path.len == 0 or absolute_path.len > 131064 or !std.fs.path.isAbsolute(absolute_path)) return error.AbsoluteOutputPathRequired;
        if (std.mem.indexOfScalar(u8, absolute_path, 0) != null) return error.EmbeddedNul;
        if (!std.unicode.utf8ValidateSlice(absolute_path)) return error.InvalidUtf8;
        if (builtin.os.tag == .windows and (std.mem.startsWith(u8, absolute_path, "\\\\?\\") or std.mem.startsWith(u8, absolute_path, "\\\\.\\") or std.mem.startsWith(u8, absolute_path, "//?/") or std.mem.startsWith(u8, absolute_path, "//./"))) return error.InvalidOutputNamespace;
        const parent = std.fs.path.dirname(absolute_path) orelse return error.AbsoluteOutputPathRequired;
        const name = std.fs.path.basename(absolute_path);
        if (!validOutputName(name)) return error.InvalidOutputName;
        // This checks the caller's private path at preparation time. It neither
        // locks that path for the Runtime nor defeats concurrent reparse changes.
        var directory = try std.fs.openDirAbsolute(parent, .{});
        defer directory.close();
        const existing = directory.statFile(name) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |entry| {
            if (!options.accept_overwrite) return error.OutputAlreadyExists;
            if (entry.kind != .file) return error.RegularOutputFileRequired;
        }
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, absolute_path);
        errdefer allocator.free(wide);
        if (wide.len > 32766) return error.OutputPathTooLong;
        const path = try allocator.dupe(u8, absolute_path);
        return .{ .allocator = allocator, .path = path, .wide = wide, .accept_overwrite = options.accept_overwrite };
    }
    pub fn validate(self: *const Destination) !void {
        const path = self.path orelse return error.DestinationConsumed;
        const wide = self.wide orelse return error.DestinationConsumed;
        if (path.len == 0 or wide.len == 0 or wide.len > 32766) return error.InvalidDownloadDestination;
    }
    pub fn deinit(self: *Destination) void {
        if (self.path) |path| self.allocator.free(path);
        if (self.wide) |wide| self.allocator.free(wide);
        self.path = null;
        self.wide = null;
    }
};

pub const Snapshot = struct {
    received_bytes: u64,
    total_bytes: ?u64,
    paused: bool,
};
pub const Completed = struct {
    snapshot: Snapshot,
    /// Borrowed during this terminal callback only. Progress snapshots avoid a
    /// path borrow that reentrant reload/cancel could invalidate mid-listener.
    path: []const u8,
};
pub const Result = union(enum) {
    /// The native transfer completed, not a promise of file signature/safety.
    completed: Completed,
    denied,
    cancelled,
    timed_out,
    detached,
    unavailable,
    timer_failed,
    limit_exceeded,
    interrupted: i32,
    native_failure: i32,
};
pub const Listener = struct { context: *anyopaque, changed: *const fn (*anyopaque, Snapshot) void };
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const DeferOptions = struct { timeout_ms: u32 = 30_000, completion: Completion };
pub const Slot = struct {
    token: u64 = 0,
    /// Informational generation when the native offer was observed. Downloads
    /// explicitly live until terminal/recover/detach, independent of navigation.
    observed_page: ?u64,
    deadline: ?u64,
    completion: ?Completion = null,
    listener: ?Listener = null,
    destination: ?Destination = null,
    active: bool = false,
};
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, slot: Slot, limit: u8) !u64 {
        if (limit == 0 or limit > capacity) return error.InvalidDownloadLimits;
        if (self.next_token == std.math.maxInt(u64)) return error.DownloadTokenExhausted;
        for (self.slots[0..limit]) |*entry| if (entry.* == null) {
            var value = slot;
            value.token = self.next_token;
            self.next_token += 1;
            entry.* = value;
            return value.token;
        };
        return error.Full;
    }
    pub fn find(self: *Book, token: u64) ?*Slot {
        for (&self.slots) |*entry| if (entry.*) |*slot| if (slot.token == token) return slot;
        return null;
    }
    pub fn take(self: *Book, token: u64) ?Slot {
        for (&self.slots) |*entry| if (entry.*) |slot| if (slot.token == token) {
            entry.* = null;
            return slot;
        };
        return null;
    }
    pub fn earliest(self: *const Book) ?u64 {
        var at: ?u64 = null;
        for (self.slots) |entry| if (entry) |slot| if (slot.deadline) |deadline| {
            at = if (at) |current| @min(current, deadline) else deadline;
        };
        return at;
    }
    pub fn tokens(self: *const Book, output: *[capacity]u64, expired_at: ?u64) []const u64 {
        var count: usize = 0;
        for (self.slots) |entry| if (entry) |slot| {
            if (expired_at) |now| if (slot.deadline == null or slot.deadline.? > now) continue;
            output[count] = slot.token;
            count += 1;
        };
        return output[0..count];
    }
};

test "download slots keep active transfers bounded without a progress clock" {
    var marker: u8 = 0;
    const completion: Completion = .{ .context = &marker, .complete = struct {
        fn complete(_: *anyopaque, _: Result) void {}
    }.complete };
    var book: Book = .{};
    const first = try book.reserve(.{ .observed_page = 1, .deadline = 100, .completion = completion }, 1);
    book.find(first).?.active = true;
    book.find(first).?.deadline = null;
    try std.testing.expect(book.earliest() == null);
    try std.testing.expectError(error.Full, book.reserve(.{ .observed_page = 2, .deadline = 200, .completion = completion }, 1));
    var tokens: [capacity]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), book.tokens(&tokens, std.math.maxInt(u64)).len);
    const old = book.tokens(&tokens, null);
    _ = book.take(first);
    const replacement = try book.reserve(.{ .observed_page = 3, .deadline = 1, .completion = completion }, 1);
    for (old) |token| _ = book.take(token);
    try std.testing.expect(book.take(replacement) != null and book.take(first) == null);
    book.next_token = std.math.maxInt(u64);
    try std.testing.expectError(error.DownloadTokenExhausted, book.reserve(.{ .observed_page = null, .deadline = 1, .completion = completion }, 1));
}

test "download grants own canonical origins and unwind every allocation" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const origins = try OwnedOrigins.init(allocator, &.{ "HTTPS://DOWNLOAD.EXAMPLE:443/", "http://127.0.0.1:1234" });
            defer origins.deinit();
            try std.testing.expectEqualStrings("https://download.example", origins.origins[0]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
    try std.testing.expectError(error.DuplicateDownloadOrigin, OwnedOrigins.init(std.testing.allocator, &.{ "https://download.example", "https://DOWNLOAD.EXAMPLE:443/" }));
    try std.testing.expectError(error.InvalidDownloadOrigin, OwnedOrigins.init(std.testing.allocator, &.{"file://private"}));
    try std.testing.expectError(error.InvalidDownloadOrigins, OwnedOrigins.init(std.testing.failing_allocator, &.{}));
}

test "destination preparation rejects main thread before touching path or allocation" {
    try std.testing.expectError(error.UiThreadForbidden, Destination.prepare(std.testing.failing_allocator, std.Thread.getCurrentId(), "not an absolute path", .{}));
}
test "Windows destination names reject device and alternate-stream aliases" {
    if (builtin.os.tag != .windows) return;
    for ([_][]const u8{ "CON", "nul.txt", "aux .bin", "COM1.bin", "lpt9", "COM¹.txt", "lpt².bin", "COM³", "conin$", "conout$.txt", "download:stream", "file.", "file ", "*.bin" }) |name| try std.testing.expect(!validOutputName(name));
    for ([_][]const u8{ "private.bin", "中文.bin", "com0.bin", "com10", "file-name_1" }) |name| try std.testing.expect(validOutputName(name));
}
test "private destination worker precheck owns metadata and unwinds each allocation" {
    const Probe = struct {
        allocator: std.mem.Allocator,
        main_thread: std.Thread.Id,
        temporary: *std.testing.TmpDir,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.work() catch |err| {
                self.err = err;
            };
        }
        fn work(self: *@This()) !void {
            const parent = try self.temporary.dir.realpathAlloc(std.testing.allocator, ".");
            defer std.testing.allocator.free(parent);
            const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "private.bin" });
            defer std.testing.allocator.free(path);
            var destination = try Destination.prepare(self.allocator, self.main_thread, path, .{});
            defer destination.deinit();
            try destination.validate();
            try std.testing.expectEqualStrings(path, destination.path.?);
            try std.testing.expect(!destination.accept_overwrite);
            const file = try self.temporary.dir.createFile("exists.bin", .{});
            file.close();
            const exists = try std.fs.path.join(std.testing.allocator, &.{ parent, "exists.bin" });
            defer std.testing.allocator.free(exists);
            try std.testing.expectError(error.OutputAlreadyExists, Destination.prepare(self.allocator, self.main_thread, exists, .{}));
            var overwrite = try Destination.prepare(self.allocator, self.main_thread, exists, .{ .accept_overwrite = true });
            defer overwrite.deinit();
        }
        fn allocationCase(allocator: std.mem.Allocator, main_thread: std.Thread.Id, temporary: *std.testing.TmpDir) !void {
            var probe: @This() = .{ .allocator = allocator, .main_thread = main_thread, .temporary = temporary };
            const worker = try std.Thread.spawn(.{}, run, .{&probe});
            worker.join();
            if (probe.err) |err| return err;
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.allocationCase, .{ std.Thread.getCurrentId(), &temporary });
}

test "download names keep the last component and number taken names" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("report.pdf", safeName(&buffer, "../../etc/report.pdf"));
    try std.testing.expectEqualStrings("a.txt", safeName(&buffer, "dir\\a.txt"));
    try std.testing.expectEqualStrings("download", safeName(&buffer, "folder/"));
    try std.testing.expectEqualStrings("download", safeName(&buffer, ".."));
    var short: [4]u8 = undefined;
    try std.testing.expectEqualStrings("a\u{00e9}", safeName(&short, "a\u{00e9}\u{00e9}"));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("a_b_.txt", safeName(&buffer, "a:b?.txt"));
        try std.testing.expectEqualStrings("_con.txt", safeName(&buffer, "con.txt"));
        try std.testing.expectEqualStrings("notes", safeName(&buffer, "notes. . "));
    }
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const Run = struct {
        fn run(dir: []const u8, out: *anyerror!void) void {
            out.* = check(dir);
        }
        fn check(dir: []const u8) !void {
            const allocator = std.testing.allocator;
            var opened = try std.fs.openDirAbsolute(dir, .{});
            defer opened.close();
            const first = try uniquePath(allocator, 0, dir, "photo.png");
            defer allocator.free(first);
            try std.testing.expectEqualStrings("photo.png", std.fs.path.basename(first));
            try opened.writeFile(.{ .sub_path = "photo.png", .data = "" });
            try opened.writeFile(.{ .sub_path = "photo (2).png", .data = "" });
            const third = try uniquePath(allocator, 0, dir, "photo.png");
            defer allocator.free(third);
            try std.testing.expectEqualStrings("photo (3).png", std.fs.path.basename(third));
            try opened.writeFile(.{ .sub_path = "notes", .data = "" });
            const plain = try uniquePath(allocator, 0, dir, "notes");
            defer allocator.free(plain);
            try std.testing.expectEqualStrings("notes (2)", std.fs.path.basename(plain));
            try std.testing.expectError(error.InvalidOutputName, uniquePath(allocator, 0, dir, "a/b"));
        }
    };
    var result: anyerror!void = {};
    const worker = try std.Thread.spawn(.{}, Run.run, .{ directory, &result });
    worker.join();
    try result;
    try std.testing.expectError(error.UiThreadForbidden, uniquePath(std.testing.allocator, std.Thread.getCurrentId(), directory, "x"));
}
