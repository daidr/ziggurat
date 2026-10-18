const std = @import("std");

pub const WordChange = extern struct { word: u32, reserved: u32 = 0, before: u64, after: u64 };
pub const Patch = struct { base: u64, revision: u64, words: []const WordChange };

/// The control's single selection bitset. Sparse nonzero words avoid scanning
/// the full catalog when replacing a small selection. Native publication gets
/// a versioned final word delta, independent of immutable labels and row data.
pub const Words = struct {
    allocator: std.mem.Allocator,
    count: usize,
    bits: []u64,
    base: []u64,
    active: []usize,
    positions: []usize,
    dirty_epochs: []u64,
    dirty_indices: []usize,
    changes: []WordChange,
    active_len: usize = 0,
    selected_count: usize = 0,
    revision: u64,
    patch_base: u64,
    epoch: u64 = 0,
    change_len: usize = 0,
    pending: bool = false,

    pub fn wordCount(count: usize) usize {
        return count / 64 + @intFromBool(count % 64 != 0);
    }
    pub fn arrayBytes(count: usize) !usize {
        return std.math.mul(usize, wordCount(count), 3 * @sizeOf(u64) + 3 * @sizeOf(usize) + @sizeOf(WordChange));
    }
    pub fn create(allocator: std.mem.Allocator, count: usize, revision: u64) !Words {
        if (count > 1_000_000 or revision == 0) return error.InvalidSelectionLimits;
        const len = wordCount(count);
        const bits = try allocator.alloc(u64, len);
        errdefer allocator.free(bits);
        const base = try allocator.alloc(u64, len);
        errdefer allocator.free(base);
        const active = try allocator.alloc(usize, len);
        errdefer allocator.free(active);
        const positions = try allocator.alloc(usize, len);
        errdefer allocator.free(positions);
        const dirty_epochs = try allocator.alloc(u64, len);
        errdefer allocator.free(dirty_epochs);
        const dirty_indices = try allocator.alloc(usize, len);
        errdefer allocator.free(dirty_indices);
        const changes = try allocator.alloc(WordChange, len);
        errdefer allocator.free(changes);
        @memset(bits, 0);
        @memset(base, 0);
        @memset(dirty_epochs, 0);
        @memset(positions, std.math.maxInt(usize));
        return .{ .allocator = allocator, .count = count, .bits = bits, .base = base, .active = active, .positions = positions, .dirty_epochs = dirty_epochs, .dirty_indices = dirty_indices, .changes = changes, .revision = revision, .patch_base = revision };
    }
    pub fn close(self: *Words) void {
        const allocator = self.allocator;
        allocator.free(self.bits);
        allocator.free(self.base);
        allocator.free(self.active);
        allocator.free(self.positions);
        allocator.free(self.dirty_epochs);
        allocator.free(self.dirty_indices);
        allocator.free(self.changes);
        self.* = undefined;
    }
    pub fn checkBegin(self: *const Words) !void {
        if (self.pending) return error.Busy;
        if (self.epoch == std.math.maxInt(u64) or self.revision == std.math.maxInt(u64)) return error.IdExhausted;
    }
    pub fn begin(self: *Words) !void {
        try self.checkBegin();
        self.epoch += 1;
        self.patch_base = self.revision;
        self.change_len = 0;
        self.pending = true;
    }
    pub fn finish(self: *Words) Patch {
        std.debug.assert(self.pending);
        var written: usize = 0;
        for (self.changes[0..self.change_len]) |change| if (change.before != change.after) {
            self.changes[written] = change;
            written += 1;
        };
        self.change_len = written;
        if (written != 0) self.revision += 1;
        self.pending = false;
        return self.patch() catch unreachable;
    }
    pub fn patch(self: *const Words) !Patch {
        if (self.pending) return error.Busy;
        return .{ .base = self.patch_base, .revision = self.revision, .words = self.changes[0..self.change_len] };
    }
    pub fn contains(self: *const Words, index: usize) bool {
        std.debug.assert(index < self.count);
        return self.bits[index / 64] & (@as(u64, 1) << @as(u6, @intCast(index % 64))) != 0;
    }
    fn assign(self: *Words, word: usize, value: u64) void {
        const previous = self.bits[word];
        if (previous == value) return;
        if (self.pending) {
            if (self.dirty_epochs[word] != self.epoch) {
                self.dirty_epochs[word] = self.epoch;
                self.dirty_indices[word] = self.change_len;
                self.changes[self.change_len] = .{ .word = @intCast(word), .before = previous, .after = value };
                self.change_len += 1;
            } else self.changes[self.dirty_indices[word]].after = value;
        }
        if (previous == 0) {
            self.positions[word] = self.active_len;
            self.active[self.active_len] = word;
            self.active_len += 1;
        } else if (value == 0) {
            self.active_len -= 1;
            const at = self.positions[word];
            const last = self.active[self.active_len];
            self.active[at] = last;
            self.positions[last] = at;
            self.positions[word] = std.math.maxInt(usize);
        }
        self.selected_count -= @popCount(previous);
        self.selected_count += @popCount(value);
        self.bits[word] = value;
    }
    pub fn initialSelect(self: *Words, index: usize) void {
        std.debug.assert(!self.pending and self.epoch == 0 and index < self.count);
        self.assign(index / 64, self.bits[index / 64] | (@as(u64, 1) << @as(u6, @intCast(index % 64))));
    }
    pub fn toggle(self: *Words, index: usize) void {
        std.debug.assert(self.pending and index < self.count);
        self.assign(index / 64, self.bits[index / 64] ^ (@as(u64, 1) << @as(u6, @intCast(index % 64))));
    }
    fn mask(first: usize, end: usize) u64 {
        const left = @as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(first));
        const right = if (end == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(end))) - 1;
        return left & right;
    }
    pub fn range(self: *Words, first: usize, end: usize, restore: bool) void {
        std.debug.assert(self.pending and first <= self.count and end <= self.count);
        if (first >= end) return;
        const last = (end - 1) / 64;
        var word = first / 64;
        while (word <= last) : (word += 1) {
            const covered = mask(if (word == first / 64) first % 64 else 0, if (word == last) (end - 1) % 64 + 1 else 64);
            self.assign(word, (self.bits[word] & ~covered) | ((if (restore) self.base[word] else std.math.maxInt(u64)) & covered));
        }
    }
    pub fn clear(self: *Words) void {
        std.debug.assert(self.pending);
        while (self.active_len != 0) self.assign(self.active[self.active_len - 1], 0);
    }
    pub fn captureBase(self: *Words, current: bool) void {
        if (current) @memcpy(self.base, self.bits) else @memset(self.base, 0);
    }
};

test "selection publication contains final touched words and no unchanged round trip" {
    var words = try Words.create(std.testing.allocator, 1_000_000, 1);
    defer words.close();
    try words.begin();
    words.range(900_000, 900_001, false);
    const first = words.finish();
    try std.testing.expectEqual(@as(usize, 1), first.words.len);
    try std.testing.expectEqual(@as(u64, 2), first.revision);
    try words.begin();
    words.clear();
    words.range(900_000, 900_001, false);
    const same = words.finish();
    try std.testing.expectEqual(@as(usize, 0), same.words.len);
    try std.testing.expectEqual(@as(u64, 2), same.revision);
    try words.begin();
    words.clear();
    words.range(1, 2, false);
    const moved = words.finish();
    try std.testing.expectEqual(@as(usize, 2), moved.words.len);
    try std.testing.expectEqual(@as(usize, 1), words.selected_count);
}

test "nonzero word sparse index survives toggles ranges clear and tail masks" {
    var words = try Words.create(std.testing.allocator, 130, 1);
    defer words.close();
    try words.begin();
    words.range(0, 130, false);
    _ = words.finish();
    try std.testing.expectEqual(@as(usize, 130), words.selected_count);
    try std.testing.expectEqual(@as(u64, 3), words.bits[2]);
    try words.begin();
    words.toggle(64);
    words.toggle(129);
    _ = words.finish();
    try std.testing.expectEqual(@as(usize, 128), words.selected_count);
    try words.begin();
    words.clear();
    _ = words.finish();
    try std.testing.expectEqual(@as(usize, 0), words.active_len);
    for (words.bits) |value| try std.testing.expectEqual(@as(u64, 0), value);
}
