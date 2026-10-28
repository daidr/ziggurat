//! The user's update choices, kept as a small JSON file: whether to check
//! automatically, whether to install without asking, the version they
//! skipped and when the last check succeeded. A damaged or missing file reads
//! as the defaults. Writes are atomic renames in the file's directory.
const std = @import("std");
const zio = @import("ziggurat_io");

pub const max_version = 64;

pub const Prefs = struct {
    /// Null until the application or the user chose.
    automatic_checks: ?bool = null,
    automatic_downloads: bool = false,
    skipped: [max_version]u8 = undefined,
    skipped_len: usize = 0,
    /// Seconds since the Unix epoch of the last successful check; 0 for none.
    last_check: i64 = 0,

    pub fn skippedVersion(self: *const Prefs) []const u8 {
        return self.skipped[0..self.skipped_len];
    }
    pub fn setSkipped(self: *Prefs, version: []const u8) void {
        const length = @min(version.len, max_version);
        @memcpy(self.skipped[0..length], version[0..length]);
        self.skipped_len = length;
    }
    pub fn eql(a: *const Prefs, b: *const Prefs) bool {
        return std.meta.eql(a.automatic_checks, b.automatic_checks) and a.automatic_downloads == b.automatic_downloads and
            std.mem.eql(u8, a.skippedVersion(), b.skippedVersion()) and a.last_check == b.last_check;
    }
};

const Wire = struct {
    automatic_checks: ?bool = null,
    automatic_downloads: bool = false,
    skipped_version: []const u8 = "",
    last_check: i64 = 0,
};

pub const file_name = "updater.json";

pub fn load(dir: std.Io.Dir) Prefs {
    var buffer: [4096]u8 = undefined;
    const bytes = dir.readFile(zio.io(), file_name, &buffer) catch return .{};
    var storage: [8192]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return .{};
    var prefs: Prefs = .{ .automatic_checks = wire.automatic_checks, .automatic_downloads = wire.automatic_downloads, .last_check = wire.last_check };
    if (wire.skipped_version.len <= max_version) prefs.setSkipped(wire.skipped_version);
    return prefs;
}

pub fn save(dir: std.Io.Dir, prefs: *const Prefs) !void {
    var json: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json);
    try std.json.Stringify.value(Wire{ .automatic_checks = prefs.automatic_checks, .automatic_downloads = prefs.automatic_downloads, .skipped_version = prefs.skippedVersion(), .last_check = prefs.last_check }, .{ .emit_null_optional_fields = false }, &writer);
    var buffer: [512]u8 = undefined;
    var atomic = try zio.AtomicFile.init(dir, file_name, .{ .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(writer.buffered());
    try atomic.finish();
}

/// When the next automatic check is due, in epoch seconds: `interval` after
/// the last success, and after a failure no sooner than the shorter of the
/// interval and an hour later. A last check in the future (the clock was
/// set back) counts as now.
pub fn nextCheck(last: i64, failed: i64, interval: i64, now: i64) i64 {
    const effective = if (last > now) now else last;
    var due = effective + interval;
    if (failed != 0) {
        const retry = failed + @min(interval, std.time.s_per_hour);
        if (retry > due) due = retry;
    }
    return due;
}

const testing = std.testing;

test "preferences round-trip and damaged files read as defaults" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try testing.expect(load(temp.dir).eql(&.{}));
    var prefs: Prefs = .{ .automatic_checks = false, .automatic_downloads = true, .last_check = 1_700_000_000 };
    prefs.setSkipped("1.4.0.0");
    try save(temp.dir, &prefs);
    try testing.expect(load(temp.dir).eql(&prefs));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = file_name, .data = "{\"automatic_downloads\":tr" });
    try testing.expect(load(temp.dir).eql(&.{}));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = file_name, .data = "{\"automatic_downloads\":true,\"future\":1}" });
    try testing.expect(load(temp.dir).automatic_downloads);
}

test "checks are due an interval after success and retry sooner after failure" {
    const day = std.time.s_per_day;
    try testing.expectEqual(1000 + day, nextCheck(1000, 0, day, 2000));
    // A failure an hour after the last success retries an hour later, not
    // a day after the failure.
    try testing.expectEqual(1000 + day, nextCheck(1000, 1000 + 3600, day, 5000));
    try testing.expectEqual(1000 + day + 3600, nextCheck(1000, 1000 + day, day, 1000 + day));
    // A short interval retries after that interval.
    try testing.expectEqual(5000 + 600, nextCheck(0, 5000, 600, 5000));
    try testing.expectEqual(2000 + day, nextCheck(9000, 0, day, 2000));
}
