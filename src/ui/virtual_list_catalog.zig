const std = @import("std");

// Private immutable input prepared on an explicit caller-chosen thread. Native
// stores must own their own copy; no late provider borrows this allocator.
pub const Authority = struct { owner: u64, generation: u64, model: u64 };
pub const Row = struct { id: u64, incarnation: u64, height_ticks: u32, label: []const u8, enabled: bool = true };
pub const Limits = struct { rows: usize = 1_000_000, bytes: usize = 64 * 1024 * 1024, text_bytes: usize = 8 * 1024 * 1024, label_bytes: usize = 4096 };
pub const Kind = enum { select, add_selection, remove_selection, focus, reveal };
pub const Action = struct {
    authority: Authority,
    publication: u64,
    id: u64,
    incarnation: u64,
    kind: Kind,
};
pub const Entry = extern struct { id: u64, incarnation: u64, height: u32, start: u32, len: u32, enabled: u32 };
pub const Identity = extern struct {
    id: u64,
    index: u64,
    fn less(_: void, a: Identity, b: Identity) bool {
        return a.id < b.id;
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    authority: Authority,
    entries: []Entry,
    ids: []Identity,
    tops: []u64,
    text: []u8,
    owned_bytes: usize,

    /// Rows and label bytes are immutable borrowed input through return.
    /// Copies every source record and label once. There are no UI calls,
    /// callbacks, hidden workers, mutable model pointers or global allocators.
    pub fn prepare(allocator: std.mem.Allocator, authority: Authority, rows: []const Row, limits: Limits) !*Prepared {
        const Slice = struct {
            rows: []const Row,
            fn row(self: @This(), index: usize) !Row {
                return self.rows[index];
            }
        };
        return prepareFrom(allocator, authority, rows.len, Slice{ .rows = rows }, limits);
    }
    /// Private compile-time reader over immutable input. It avoids a second
    /// temporary N-row descriptor array when an owner snapshots its own index.
    /// Reader calls make no foreign callbacks or UI writes; source storage
    /// stays fixed throughout validation and the following copy.
    pub fn prepareFrom(allocator: std.mem.Allocator, authority: Authority, count_: usize, source: anytype, limits: Limits) !*Prepared {
        return prepareFrozen(allocator.ptr, allocator.vtable, authority.owner, authority.generation, authority.model, count_, source, limits.rows, limits.bytes, limits.text_bytes, limits.label_bytes);
    }
    noinline fn prepareFrozen(allocator_ptr: *anyopaque, allocator_vtable: *const std.mem.Allocator.VTable, owner: u64, generation: u64, model: u64, count_: usize, source: anytype, max_rows_: usize, bytes: usize, max_text: usize, max_label: usize) !*Prepared {
        const allocator: std.mem.Allocator = .{ .ptr = allocator_ptr, .vtable = allocator_vtable };
        const authority: Authority = .{ .owner = owner, .generation = generation, .model = model };
        const limits: Limits = .{ .rows = max_rows_, .bytes = bytes, .text_bytes = max_text, .label_bytes = max_label };
        if (authority.owner == 0 or authority.generation == 0 or authority.model == 0) return error.InvalidCatalogAuthority;
        if (limits.rows == 0 or limits.rows > 1_000_000 or limits.bytes < @sizeOf(Prepared) or limits.bytes > 64 * 1024 * 1024 or limits.text_bytes > 8 * 1024 * 1024 or limits.label_bytes == 0 or limits.label_bytes > 4096) return error.InvalidCatalogLimits;
        if (count_ > limits.rows) return error.TooManyRows;
        var text_bytes: usize = 0;
        for (0..count_) |index| {
            const record = try source.row(index);
            if (record.id == 0 or record.incarnation == 0 or record.height_ticks == 0 or record.height_ticks > 64_000_000) return error.InvalidCatalogRow;
            if (!std.unicode.utf8ValidateSlice(record.label) or std.mem.indexOfScalar(u8, record.label, 0) != null) return error.InvalidCatalogText;
            if (record.label.len > limits.label_bytes or record.label.len > limits.text_bytes -| text_bytes) return error.CatalogTextExceeded;
            text_bytes += record.label.len;
        }
        const row_bytes = try std.math.mul(usize, count_, @sizeOf(Entry) + @sizeOf(Identity));
        const top_bytes = try std.math.mul(usize, try std.math.add(usize, count_, 1), @sizeOf(u64));
        const owned_bytes = try std.math.add(usize, @sizeOf(Prepared), try std.math.add(usize, row_bytes, try std.math.add(usize, top_bytes, text_bytes)));
        if (owned_bytes > limits.bytes) return error.CatalogBudgetExceeded;
        const self = try allocator.create(Prepared);
        errdefer allocator.destroy(self);
        const entries = try allocator.alloc(Entry, count_);
        errdefer allocator.free(entries);
        const ids = try allocator.alloc(Identity, count_);
        errdefer allocator.free(ids);
        const tops = try allocator.alloc(u64, count_ + 1);
        errdefer allocator.free(tops);
        const text = try allocator.alloc(u8, text_bytes);
        errdefer allocator.free(text);
        var used: usize = 0;
        tops[0] = 0;
        for (0..count_) |index| {
            const record = try source.row(index);
            entries[index] = .{ .id = record.id, .incarnation = record.incarnation, .height = record.height_ticks, .start = @intCast(used), .len = @intCast(record.label.len), .enabled = @intFromBool(record.enabled) };
            ids[index] = .{ .id = record.id, .index = index };
            @memcpy(text[used..][0..record.label.len], record.label);
            used += record.label.len;
            tops[index + 1] = tops[index] + record.height_ticks;
        }
        if (@hasDecl(@TypeOf(source), "sortedIdentity")) {
            for (ids, 0..) |*entry, index| {
                entry.* = try source.sortedIdentity(index);
                if (entry.index >= entries.len or entries[@intCast(entry.index)].id != entry.id) return error.InvalidCatalogRow;
            }
        } else std.sort.heap(Identity, ids, {}, Identity.less);
        if (ids.len > 1) for (ids[1..], ids[0 .. ids.len - 1]) |next, previous| {
            if (next.id == previous.id) return error.DuplicateId;
            if (next.id < previous.id) return error.InvalidCatalogRow;
        };
        self.* = .{ .allocator = allocator, .authority = authority, .entries = entries, .ids = ids, .tops = tops, .text = text, .owned_bytes = owned_bytes };
        return self;
    }
    pub fn close(self: *Prepared) void {
        const allocator = self.allocator;
        allocator.free(self.entries);
        allocator.free(self.ids);
        allocator.free(self.tops);
        allocator.free(self.text);
        allocator.destroy(self);
    }
    pub fn count(self: *const Prepared) usize {
        return self.entries.len;
    }
    pub fn row(self: *const Prepared, index: usize) !Row {
        if (index >= self.entries.len) return error.InvalidIndex;
        const entry = self.entries[index];
        return .{ .id = entry.id, .incarnation = entry.incarnation, .height_ticks = entry.height, .label = self.text[entry.start..][0..entry.len], .enabled = entry.enabled != 0 };
    }
    pub fn find(self: *const Prepared, id: u64) ?usize {
        var low: usize = 0;
        var high = self.ids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.ids[middle].id < id) low = middle + 1 else high = middle;
        }
        return if (low < self.ids.len and self.ids[low].id == id) @intCast(self.ids[low].index) else null;
    }
    pub fn rowTopTicks(self: *const Prepared, index: usize) !u64 {
        if (index > self.entries.len) return error.InvalidIndex;
        return self.tops[index];
    }
    /// Called at native request time against that request's immutable catalog.
    /// Dispatch must validate this captured identity, never substitute a record.
    pub fn capture(self: *const Prepared, publication: u64, index: usize, kind: Kind) !Action {
        if (publication == 0) return error.InvalidCatalogAuthority;
        const entry = try self.row(index);
        if (!entry.enabled) return error.RowDisabled;
        return .{ .authority = self.authority, .publication = publication, .id = entry.id, .incarnation = entry.incarnation, .kind = kind };
    }
};

test "catalog owns full offscreen labels and captures request time row authority" {
    var label = [_]u8{ 'o', 'l', 'd' };
    const authority: Authority = .{ .owner = 5, .generation = 2, .model = 9 };
    const prepared = try Prepared.prepare(std.testing.allocator, authority, &.{
        .{ .id = 88, .incarnation = 30, .height_ticks = 640, .label = "first" },
        .{ .id = 22, .incarnation = 31, .height_ticks = 1280, .label = &label },
    }, .{});
    defer prepared.close();
    @memset(&label, 'x');
    try std.testing.expectEqualStrings("old", (try prepared.row(1)).label);
    try std.testing.expectEqual(@as(?usize, 1), prepared.find(22));
    try std.testing.expectEqual(@as(u64, 1920), try prepared.rowTopTicks(2));
    const request = try prepared.capture(15, 1, .select);
    try std.testing.expectEqualDeep(Action{ .authority = authority, .publication = 15, .id = 22, .incarnation = 31, .kind = .select }, request);
    // A later catalog with the same ID has an independent row incarnation.
    const next = try Prepared.prepare(std.testing.allocator, .{ .owner = 5, .generation = 2, .model = 11 }, &.{.{ .id = 22, .incarnation = 32, .height_ticks = 640, .label = "new" }}, .{});
    defer next.close();
    try std.testing.expect(request.incarnation != (try next.row(0)).incarnation);
}

test "catalog empty state malformed identity text and explicit budgets" {
    const authority: Authority = .{ .owner = 1, .generation = 1, .model = 1 };
    const empty = try Prepared.prepare(std.testing.allocator, authority, &.{}, .{});
    defer empty.close();
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    try std.testing.expectEqual(@as(u64, 0), try empty.rowTopTicks(0));
    try std.testing.expect(empty.find(1) == null);
    const row_value: Row = .{ .id = 1, .incarnation = 2, .height_ticks = 64, .label = "row" };
    try std.testing.expectError(error.DuplicateId, Prepared.prepare(std.testing.allocator, authority, &.{ row_value, row_value }, .{}));
    try std.testing.expectError(error.CatalogTextExceeded, Prepared.prepare(std.testing.allocator, authority, &.{row_value}, .{ .text_bytes = 2 }));
    try std.testing.expectError(error.CatalogBudgetExceeded, Prepared.prepare(std.testing.allocator, authority, &.{row_value}, .{ .bytes = @sizeOf(Prepared) }));
    try std.testing.expectError(error.InvalidCatalogText, Prepared.prepare(std.testing.allocator, authority, &.{.{ .id = 1, .incarnation = 2, .height_ticks = 64, .label = "bad\x00text" }}, .{}));
}

test "every immutable catalog allocation failure frees owned input" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const prepared = try Prepared.prepare(allocator, .{ .owner = 1, .generation = 2, .model = 3 }, &.{
                .{ .id = 11, .incarnation = 1, .height_ticks = 1, .label = "one" },
                .{ .id = 22, .incarnation = 2, .height_ticks = 2, .label = "two" },
            }, .{});
            defer prepared.close();
            try std.testing.expectEqual(@as(u64, 3), try prepared.rowTopTicks(2));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "an explicit worker prepares input without borrowing a live owner" {
    const Probe = struct {
        output: ?*Prepared = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.output = Prepared.prepare(std.testing.allocator, .{ .owner = 1, .generation = 2, .model = 3 }, &.{.{ .id = 11, .incarnation = 4, .height_ticks = 640, .label = "worker" }}, .{}) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var probe: Probe = .{};
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    if (probe.failure) |err| return err;
    const prepared = probe.output.?;
    defer prepared.close();
    try std.testing.expectEqualStrings("worker", (try prepared.row(0)).label);
}

test "catalog reuses sorted identity reader and validates its permutation" {
    const Reader = struct {
        ids: []const Identity,
        pub fn row(_: @This(), index: usize) !Row {
            return .{ .id = ([_]u64{ 90, 10, 50 })[index], .incarnation = index + 1, .height_ticks = 64, .label = "row" };
        }
        pub fn sortedIdentity(self: @This(), index: usize) !Identity {
            return self.ids[index];
        }
    };
    const authority: Authority = .{ .owner = 1, .generation = 2, .model = 3 };
    const good = [_]Identity{ .{ .id = 10, .index = 1 }, .{ .id = 50, .index = 2 }, .{ .id = 90, .index = 0 } };
    const prepared = try Prepared.prepareFrom(std.testing.allocator, authority, 3, Reader{ .ids = &good }, .{});
    defer prepared.close();
    try std.testing.expectEqual(@as(?usize, 1), prepared.find(10));
    try std.testing.expectEqual(@as(?usize, 0), prepared.find(90));
    const bad = [_]Identity{ .{ .id = 10, .index = 0 }, good[1], good[2] };
    try std.testing.expectError(error.InvalidCatalogRow, Prepared.prepareFrom(std.testing.allocator, authority, 3, Reader{ .ids = &bad }, .{}));
    const duplicate = [_]Identity{ good[0], good[0], good[2] };
    try std.testing.expectError(error.DuplicateId, Prepared.prepareFrom(std.testing.allocator, authority, 3, Reader{ .ids = &duplicate }, .{}));
    const descending = [_]Identity{ good[1], good[0], good[2] };
    try std.testing.expectError(error.InvalidCatalogRow, Prepared.prepareFrom(std.testing.allocator, authority, 3, Reader{ .ids = &descending }, .{}));
}

test "catalog freezes authority and limits before caller allocation" {
    const Probe = struct {
        limits: *Limits,
        authority: *Authority,
        calls: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.limits.* = .{ .rows = 0, .bytes = 0, .text_bytes = 0, .label_bytes = 0 };
            self.authority.* = .{ .owner = 88, .generation = 99, .model = 100 };
            return std.testing.allocator.rawAlloc(size, alignment, ra);
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ra);
        }
    };
    var limits: Limits = .{};
    var authority: Authority = .{ .owner = 1, .generation = 2, .model = 3 };
    var probe: Probe = .{ .limits = &limits, .authority = &authority };
    const prepared = try Prepared.prepare(probe.allocator(), authority, &.{.{ .id = 10, .incarnation = 9, .height_ticks = 64, .label = "frozen" }}, limits);
    defer prepared.close();
    try std.testing.expectEqualDeep(Authority{ .owner = 1, .generation = 2, .model = 3 }, prepared.authority);
    try std.testing.expectEqual(@as(usize, 5), probe.calls);
    try std.testing.expectEqualStrings("frozen", (try prepared.row(0)).label);
}
