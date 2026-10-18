const std = @import("std");
const d = @import("ziggurat_document");

pub const Limits = struct {
    bytes: usize = 32 * 1024 * 1024,
    utf16_units: usize = 2 * 1024 * 1024,
    scalar_boundaries: usize = 2 * 1024 * 1024 + 1,
    paragraphs: usize = 262145,
};
pub const Stamp = struct { revision: u64, text_version: u64, bytes: usize };
pub const Range = struct { start: u32, end: u32 };

/// Complete, immutable committed text for a native provider candidate. This is
/// derived storage, never editable authority. Construction is O(source bytes),
/// starts no worker and retains no Reader, Snapshot, Document or allocator box.
/// An explicit worker may build it using the host's transferred Reader lease.
pub const Text = struct {
    allocator: std.mem.Allocator,
    utf16: []u16,
    scalars: []u32,
    paragraphs: []u32,
    stamp: Stamp,
    owned_bytes: usize,
    owned: bool = true,

    pub fn create(allocator: std.mem.Allocator, source: d.Reader, limits: Limits) !Text {
        try validateLimits(limits);
        const units = try source.utf16Length();
        const scalar_count = std.math.add(usize, try source.scalarLength(), 1) catch return error.CapacityExceeded;
        const paragraph_count = std.math.add(usize, try source.lineCount(), 1) catch return error.CapacityExceeded;
        if (units > limits.utf16_units or scalar_count > limits.scalar_boundaries or paragraph_count > limits.paragraphs) return error.CapacityExceeded;
        const bytes = try footprint(units, scalar_count, paragraph_count);
        if (bytes > limits.bytes) return error.CapacityExceeded;
        const utf16 = try allocator.alloc(u16, units);
        errdefer allocator.free(utf16);
        const scalars = try allocator.alloc(u32, scalar_count);
        errdefer allocator.free(scalars);
        const paragraphs = try allocator.alloc(u32, paragraph_count);
        errdefer allocator.free(paragraphs);
        const stamp: Stamp = .{ .revision = try source.version(), .text_version = try source.committedTextVersion(), .bytes = try source.byteLength() };
        var cursor = try source.cursor(.{ .start = 0, .end = stamp.bytes });
        var offset: usize = 0;
        var scalar: usize = 0;
        var paragraph: usize = 1;
        scalars[0] = 0;
        paragraphs[0] = 0;
        while (try cursor.next()) |part| {
            var iterator = std.unicode.Utf8View.initUnchecked(part.bytes).iterator();
            while (iterator.nextCodepoint()) |cp| {
                if (cp <= 0xffff) {
                    utf16[offset] = @intCast(cp);
                    offset += 1;
                } else {
                    const value: u32 = cp - 0x10000;
                    utf16[offset] = @intCast(0xd800 + (value >> 10));
                    utf16[offset + 1] = @intCast(0xdc00 + (value & 0x3ff));
                    offset += 2;
                }
                scalar += 1;
                scalars[scalar] = @intCast(offset);
                if (cp == '\n') {
                    paragraphs[paragraph] = @intCast(offset);
                    paragraph += 1;
                }
            }
        }
        std.debug.assert(offset == units and scalar + 1 == scalar_count and paragraph + 1 == paragraph_count);
        // A terminal LF has an empty terminal paragraph. Keep its duplicate end
        // boundary: it represents the Document's actual caret line, not a row
        // synthesized by comparison or visible paragraph enumeration.
        paragraphs[paragraph] = @intCast(offset);
        return .{ .allocator = allocator, .utf16 = utf16, .scalars = scalars, .paragraphs = paragraphs, .stamp = stamp, .owned_bytes = bytes };
    }
    pub fn isOwned(self: *const Text) bool {
        return self.owned;
    }
    pub fn take(self: *Text) !Text {
        if (!self.owned) return error.TextMoved;
        const result = self.*;
        self.owned = false;
        self.utf16 = &.{};
        self.scalars = &.{};
        self.paragraphs = &.{};
        self.owned_bytes = 0;
        return result;
    }
    pub fn deinit(self: *Text) void {
        if (!self.owned) return;
        const allocator = self.allocator;
        const utf16 = self.utf16;
        const scalars = self.scalars;
        const paragraphs = self.paragraphs;
        self.owned = false;
        self.utf16 = &.{};
        self.scalars = &.{};
        self.paragraphs = &.{};
        self.owned_bytes = 0;
        allocator.free(utf16);
        allocator.free(scalars);
        allocator.free(paragraphs);
    }
    pub fn validateRange(self: *const Text, range: Range) !void {
        if (!self.owned) return error.TextMoved;
        if (range.start > range.end or range.end > self.utf16.len) return error.InvalidRange;
        if (!self.scalarBoundary(range.start) or !self.scalarBoundary(range.end)) return error.InvalidBoundary;
    }
    pub fn scalarBoundary(self: *const Text, unit: u32) bool {
        var lo: usize = 0;
        var hi = self.scalars.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.scalars[mid] < unit) lo = mid + 1 else hi = mid;
        }
        return lo < self.scalars.len and self.scalars[lo] == unit;
    }
};
pub fn validateLimits(limits: Limits) !void {
    if (limits.bytes == 0 or limits.bytes > 1024 * 1024 * 1024 or limits.utf16_units == 0 or limits.utf16_units > 64 * 1024 * 1024 or limits.scalar_boundaries == 0 or limits.scalar_boundaries > 64 * 1024 * 1024 + 1 or limits.paragraphs < 2 or limits.paragraphs > 2097154) return error.InvalidLimits;
}
pub fn footprint(units: usize, scalars: usize, paragraphs: usize) !usize {
    const text_bytes = std.math.mul(usize, units, @sizeOf(u16)) catch return error.CapacityExceeded;
    const scalar_bytes = std.math.mul(usize, scalars, @sizeOf(u32)) catch return error.CapacityExceeded;
    const paragraph_bytes = std.math.mul(usize, paragraphs, @sizeOf(u32)) catch return error.CapacityExceeded;
    return std.math.add(usize, text_bytes, std.math.add(usize, scalar_bytes, paragraph_bytes) catch return error.CapacityExceeded) catch error.CapacityExceeded;
}

test {
    _ = @import("model_test.zig");
}
