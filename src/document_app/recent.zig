const std = @import("std");
const id = @import("identity.zig");

const header = "ziggurat-recent 1\n";

/// Most-recently-used document paths in caller storage, newest first. Owned
/// by one thread; persist with `encode`/`decode` and `Files` on a worker.
pub const Recent = struct {
    entries: []id.Path,
    len: usize = 0,

    pub fn init(storage: []id.Path) Recent {
        return .{ .entries = storage };
    }
    pub fn items(self: *const Recent) []const id.Path {
        return self.entries[0..self.len];
    }
    fn indexOf(self: *const Recent, path: []const u8) ?usize {
        for (self.items(), 0..) |*entry, at| if (id.pathEql(entry.slice(), path)) return at;
        return null;
    }
    /// Moves an existing entry to the front or inserts a new one, evicting the
    /// oldest when full. Paths must be absolute; use canonical identity paths
    /// so alternate spellings do not create duplicates.
    pub fn add(self: *Recent, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
        const value = try id.Path.init(path);
        if (self.entries.len == 0) return error.CapacityExceeded;
        const end = self.indexOf(path) orelse if (self.len < self.entries.len) blk: {
            self.len += 1;
            break :blk self.len - 1;
        } else self.len - 1;
        var at = end;
        while (at > 0) : (at -= 1) self.entries[at] = self.entries[at - 1];
        self.entries[0] = value;
    }
    pub fn remove(self: *Recent, path: []const u8) bool {
        const at = self.indexOf(path) orelse return false;
        for (at..self.len - 1) |next| self.entries[next] = self.entries[next + 1];
        self.len -= 1;
        return true;
    }
    pub fn clear(self: *Recent) void {
        self.len = 0;
    }
    pub fn encode(self: *const Recent, output: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(output);
        writer.writeAll(header) catch return error.NoSpaceLeft;
        for (self.items()) |*entry| writer.print("{s}\n", .{entry.slice()}) catch return error.NoSpaceLeft;
        return writer.buffered();
    }
    /// Replaces the list only when the whole input is valid. Entries beyond
    /// capacity (oldest last) are dropped; duplicates keep the newest position.
    pub fn decode(self: *Recent, bytes: []const u8) !void {
        if (!std.mem.startsWith(u8, bytes, header) or !std.mem.endsWith(u8, bytes, "\n")) return error.InvalidFormat;
        const body = bytes[header.len..];
        var lines = std.mem.splitScalar(u8, body[0..body.len -| 1], '\n');
        if (body.len != 0) while (lines.next()) |line| {
            if (!std.fs.path.isAbsolute(line)) return error.InvalidFormat;
            _ = id.Path.init(line) catch return error.InvalidFormat;
        };
        self.clear();
        if (body.len == 0) return;
        var reverse = std.mem.splitBackwardsScalar(u8, body[0 .. body.len - 1], '\n');
        while (reverse.next()) |line| try self.add(line);
    }
};
