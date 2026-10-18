const std = @import("std");

/// A separate sending capability. It never grants navigation, methods or IPC.
/// The host supplies private random bytes; wire form is Bearer + lowercase hex.
pub const Entry = struct { origin: []const u8, bearer: [32]u8 };
pub const max_entries = 8;

/// Capture before invoking a caller allocator. Addresses refer to this stable
/// stack object, so initialize in place and do not copy an initialized Capture.
pub const Capture = struct {
    entries: [max_entries]Entry = undefined,
    origins: [max_entries][1024]u8 = undefined,
    count: usize = 0,

    pub fn init(self: *Capture, entries: []const Entry) !void {
        self.count = 0;
        if (entries.len > max_entries) return error.TooManyRequestCredentials;
        for (entries, 0..) |*entry, index| {
            if (entry.origin.len == 0 or entry.origin.len > 1024) return error.InvalidCredentialOrigin;
            @memcpy(self.origins[index][0..entry.origin.len], entry.origin);
            self.entries[index] = .{ .origin = self.origins[index][0..entry.origin.len], .bearer = entry.bearer };
            self.count += 1;
        }
    }
    pub fn deinit(self: *Capture) void {
        for (self.entries[0..self.count]) |*entry| std.crypto.secureZero(u8, &entry.bearer);
        self.count = 0;
    }
};
