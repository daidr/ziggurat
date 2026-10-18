const std = @import("std");
const codec = @import("codec.zig");
const positions = @import("positions.zig");

pub const Entry = struct { scope_uri: ?[]const u8 = null, section: ?[]const u8 = null, value_json: []const u8 };
pub const Input = struct { settings_json: []const u8, entries: []const Entry = &.{} };
pub const Limits = struct {
    source_bytes: usize = 64 * 1024,
    bytes: usize = 2 * 1024 * 1024,
    entries: usize = 64,
    items: usize = 32,
    query_bytes: usize = 256 * 1024,
    response_bytes: usize = 256 * 1024,
    work_bytes: usize = 8 * 1024 * 1024,
    tokens: usize = 8192,
    depth: usize = 32,
    pub fn validate(self: Limits) !void {
        if (self.source_bytes == 0 or self.source_bytes > 1024 * 1024 or self.bytes < @sizeOf(Snapshot) or self.bytes > 16 * 1024 * 1024 or self.entries > 256 or self.items == 0 or self.items > 64 or self.query_bytes < @sizeOf(Query) or self.query_bytes > 1024 * 1024 or self.response_bytes < 2048 or self.response_bytes > 16 * 1024 * 1024 or self.work_bytes == 0 or self.work_bytes > 64 * 1024 * 1024 or self.tokens == 0 or self.tokens > 1024 * 1024 or self.depth == 0 or self.depth > 64) return error.InvalidLimits;
    }
};
pub const Preparation = struct { limits: Limits = .{}, cancellation: ?*const positions.Cancellation = null };
pub const Stats = struct { bytes: usize, peak_bytes: usize, source_bytes: usize, tokens: usize, depth: usize, work_bytes: usize, entries: usize };
fn checkCancellation(flag: ?*const positions.Cancellation) !void {
    if (flag) |value| if (value.requested.load(.acquire)) return error.Cancelled;
}
fn charge(total: *usize, amount: usize, limit: usize) !void {
    if (total.* > limit or amount > limit - total.*) return error.ConfigurationCapacityExceeded;
    total.* += amount;
}
fn key(value: ?[]const u8, maximum: usize, empty: bool) !void {
    if (value) |bytes| if (bytes.len > maximum or (!empty and bytes.len == 0) or !std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidConfigurationKey;
}
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
/// Validated raw JSON preserves the host's number/string representation. Only
/// this module constructs values passed to the bounded packet writer.
pub const Raw = struct {
    bytes: []const u8,
    pub fn jsonStringify(self: Raw, writer: *std.json.Stringify) !void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll(self.bytes);
        writer.endWriteRaw();
    }
};
pub const Snapshot = struct {
    budget: Budget,
    entries: []Entry = &.{},
    storage: []u8 = &.{},
    settings: []const u8 = "null",
    stats: Stats,
    references: usize = 1,
    pub fn retain(self: *Snapshot) !void {
        if (self.references == std.math.maxInt(usize)) return error.CapacityExceeded;
        self.references += 1;
    }
    pub fn release(self: *Snapshot) void {
        std.debug.assert(self.references != 0);
        self.references -= 1;
        if (self.references != 0) return;
        const allocator = self.budget.child;
        self.budget.allocator().free(self.entries);
        self.budget.allocator().free(self.storage);
        allocator.destroy(self);
    }
    pub fn fits(self: *const Snapshot, limits: Limits, framing: codec.Limits) !void {
        if (self.stats.peak_bytes > limits.bytes or self.stats.source_bytes > limits.source_bytes or self.stats.entries > limits.entries or self.stats.tokens > limits.tokens or self.stats.depth > limits.depth or self.stats.work_bytes > limits.work_bytes) return error.ConfigurationCapacityExceeded;
        if (self.stats.depth + 3 > framing.depth) return error.DepthCapacityExceeded;
    }
};
/// Independent worker-prepared linear product. No Client/IO/native dependency.
/// After worker join, owner move consumes it only on success; errors keep it.
pub const Prepared = struct {
    snapshot: ?*Snapshot,
    busy: bool = false,
    cancellation: ?*const positions.Cancellation = null,
    pub fn create(allocator: std.mem.Allocator, input: Input, options: Preparation) !Prepared {
        const limits = options.limits;
        try limits.validate();
        try checkCancellation(options.cancellation);
        if (input.entries.len > limits.entries) return error.ConfigurationCapacityExceeded;
        var source: usize = 0;
        var work: usize = 0;
        try charge(&source, input.settings_json.len, limits.source_bytes);
        for (input.entries, 0..) |entry, index| {
            try checkCancellation(options.cancellation);
            try key(entry.scope_uri, 4096, false);
            try key(entry.section, 256, true);
            try charge(&source, entry.value_json.len, limits.source_bytes);
            try charge(&source, if (entry.scope_uri) |value| value.len else 0, limits.source_bytes);
            try charge(&source, if (entry.section) |value| value.len else 0, limits.source_bytes);
            for (input.entries[0..index]) |before| {
                const amount = (if (entry.scope_uri) |value| value.len else 0) + (if (entry.section) |value| value.len else 0) + (if (before.scope_uri) |value| value.len else 0) + (if (before.section) |value| value.len else 0) + 1;
                try charge(&work, amount, limits.work_bytes);
                if (optionalEqual(entry.scope_uri, before.scope_uri) and optionalEqual(entry.section, before.section)) return error.DuplicateConfiguration;
            }
        }
        try charge(&work, source * 8, limits.work_bytes);
        if (source + input.entries.len * @sizeOf(Entry) + @sizeOf(Snapshot) > limits.bytes) return error.ConfigurationCapacityExceeded;
        const snapshot = try allocator.create(Snapshot);
        snapshot.* = .{ .budget = .{ .child = allocator, .limit = limits.bytes, .live = @sizeOf(Snapshot), .peak = @sizeOf(Snapshot) }, .stats = .{ .bytes = 0, .peak_bytes = 0, .source_bytes = source, .tokens = 0, .depth = 0, .work_bytes = work, .entries = input.entries.len } };
        errdefer snapshot.release();
        const owned = snapshot.budget.allocator();
        snapshot.entries = owned.alloc(Entry, input.entries.len) catch |err| return snapshot.budget.failure(err);
        snapshot.storage = owned.alloc(u8, source) catch |err| return snapshot.budget.failure(err);
        var cursor: usize = 0;
        snapshot.settings = copy(snapshot.storage, &cursor, input.settings_json);
        for (input.entries, snapshot.entries) |entry, *target| target.* = .{ .scope_uri = if (entry.scope_uri) |value| copy(snapshot.storage, &cursor, value) else null, .section = if (entry.section) |value| copy(snapshot.storage, &cursor, value) else null, .value_json = copy(snapshot.storage, &cursor, entry.value_json) };
        var validation: codec.Limits = .{ .body_bytes = limits.source_bytes, .json_bytes = limits.bytes, .depth = limits.depth, .tokens = limits.tokens };
        const settings_stats = codec.validateValue(owned, snapshot.settings, validation) catch |err| return snapshot.budget.failure(err);
        snapshot.stats.tokens = settings_stats.tokens;
        snapshot.stats.depth = settings_stats.depth;
        try checkCancellation(options.cancellation); // Includes final tree free.
        for (snapshot.entries) |entry| {
            if (snapshot.stats.tokens == limits.tokens) return error.TokenCapacityExceeded;
            validation.tokens = limits.tokens - snapshot.stats.tokens;
            const scanned = codec.validateValue(owned, entry.value_json, validation) catch |err| return snapshot.budget.failure(err);
            snapshot.stats.tokens += scanned.tokens;
            snapshot.stats.depth = @max(snapshot.stats.depth, scanned.depth);
            try checkCancellation(options.cancellation);
        }
        snapshot.stats.bytes = snapshot.budget.live;
        snapshot.stats.peak_bytes = snapshot.budget.peak;
        return .{ .snapshot = snapshot, .cancellation = options.cancellation };
    }
    pub fn check(self: *const Prepared) !*Snapshot {
        if (self.busy) return error.Busy;
        const snapshot = self.snapshot orelse return error.Closed;
        try checkCancellation(self.cancellation);
        return snapshot;
    }
    pub fn stats(self: *const Prepared) !Stats {
        if (self.busy) return error.Busy;
        return (self.snapshot orelse return error.Closed).stats;
    }
    pub fn close(self: *Prepared) !void {
        if (self.busy) return error.Busy;
        const snapshot = self.snapshot orelse return error.Closed;
        self.snapshot = null; // Withdraw before foreign frees; no later self read.
        snapshot.release();
    }
};
fn copy(storage: []u8, at: *usize, bytes: []const u8) []const u8 {
    const result = storage[at.*..][0..bytes.len];
    @memcpy(result, bytes);
    at.* += bytes.len;
    return result;
}
pub const Item = struct { scope_uri: ?[]const u8, section: ?[]const u8 };
/// Immutable by-value query metadata owns all keys, not the temporary Message.
pub const Query = struct {
    allocator: std.mem.Allocator,
    items: []Item,
    storage: []u8,
    work: usize,
    pub fn create(allocator: std.mem.Allocator, params: ?std.json.Value, limits: Limits) !*Query {
        try limits.validate();
        const object = params orelse return error.InvalidParams;
        if (object != .object) return error.InvalidParams;
        const values = object.object.get("items") orelse return error.InvalidParams;
        if (values != .array or values.array.items.len > limits.items) return error.InvalidParams;
        var bytes: usize = @sizeOf(Query) + values.array.items.len * @sizeOf(Item);
        var work: usize = 0;
        for (values.array.items) |value| {
            const item = try readItem(value);
            const length = (if (item.scope_uri) |string| string.len else 0) + (if (item.section) |string| string.len else 0);
            try charge(&bytes, length, limits.query_bytes);
            try charge(&work, length * 4 + 1, limits.work_bytes);
        }
        if (bytes > limits.query_bytes) return error.ConfigurationCapacityExceeded;
        const self = try allocator.create(Query);
        errdefer allocator.destroy(self);
        const items = try allocator.alloc(Item, values.array.items.len);
        errdefer allocator.free(items);
        const storage = try allocator.alloc(u8, bytes - @sizeOf(Query) - items.len * @sizeOf(Item));
        errdefer allocator.free(storage);
        var at: usize = 0;
        for (values.array.items, items) |value, *item| {
            const before = try readItem(value);
            item.* = .{ .scope_uri = if (before.scope_uri) |string| copy(storage, &at, string) else null, .section = if (before.section) |string| copy(storage, &at, string) else null };
        }
        self.* = .{ .allocator = allocator, .items = items, .storage = storage, .work = work };
        return self;
    }
    fn readItem(value: std.json.Value) !Item {
        if (value != .object) return error.InvalidParams;
        var result: Item = .{ .scope_uri = null, .section = null };
        if (value.object.get("scopeUri")) |scope| {
            if (scope != .string) return error.InvalidParams;
            result.scope_uri = scope.string;
        }
        if (value.object.get("section")) |section| {
            if (section != .string) return error.InvalidParams;
            result.section = section.string;
        }
        try key(result.scope_uri, 4096, false);
        try key(result.section, 256, true);
        return result;
    }
    pub fn results(self: *const Query, snapshot: *const Snapshot, limits: Limits, output: *[64]Raw) ![]const Raw {
        try limits.validate();
        var work = self.work;
        var response: usize = 0;
        try charge(&response, 2048, limits.response_bytes); // Envelope + worst escaped 256B ID.
        var candidate: [64]Raw = undefined;
        for (self.items, 0..) |item, index| {
            var selected: []const u8 = "null";
            for (snapshot.entries) |entry| {
                const length = (if (item.scope_uri) |string| string.len else 0) + (if (item.section) |string| string.len else 0) + (if (entry.scope_uri) |string| string.len else 0) + (if (entry.section) |string| string.len else 0) + 1;
                try charge(&work, length, limits.work_bytes);
                if (optionalEqual(item.scope_uri, entry.scope_uri) and optionalEqual(item.section, entry.section)) {
                    selected = entry.value_json;
                    break;
                }
            }
            try charge(&response, selected.len + 1, limits.response_bytes);
            try charge(&work, selected.len * 4, limits.work_bytes);
            candidate[index] = .{ .bytes = selected };
        }
        @memcpy(output[0..self.items.len], candidate[0..self.items.len]);
        return output[0..self.items.len];
    }
    pub fn close(self: *Query) void {
        const allocator = self.allocator;
        allocator.free(self.items);
        allocator.free(self.storage);
        allocator.destroy(self);
    }
};

fn ownedFixture(allocator: std.mem.Allocator) !void {
    var prepared = try Prepared.create(allocator, .{ .settings_json = " {\"large\":123456789012345678901234567890,\"v\":true} ", .entries = &.{ .{ .section = "language", .value_json = "{\"n\":1}" }, .{ .scope_uri = "file:///a/doc", .section = "language", .value_json = "2" }, .{ .section = "", .value_json = "false" }, .{ .value_json = "[1,2]" } } }, .{});
    defer prepared.close() catch unreachable;
    const message = try codec.Message.parse(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"language\"},{\"scopeUri\":\"file:///a/doc\",\"section\":\"language\"},{\"section\":\"\"},{},{\"scopeUri\":\"file:///unknown\",\"section\":\"language\"}]} }", .{});
    defer message.close() catch unreachable;
    const query = try Query.create(allocator, (try message.value()).request.params, .{});
    defer query.close();
    var results: [64]Raw = undefined;
    const values = try query.results(prepared.snapshot.?, .{}, &results);
    try std.testing.expectEqualStrings("{\"n\":1}", values[0].bytes);
    try std.testing.expectEqualStrings("2", values[1].bytes);
    try std.testing.expectEqualStrings("false", values[2].bytes);
    try std.testing.expectEqualStrings("[1,2]", values[3].bytes);
    try std.testing.expectEqualStrings("null", values[4].bytes);
    var packet = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = 1, .result = values }, .{});
    defer packet.deinit();
    try std.testing.expect((try prepared.stats()).peak_bytes >= (try prepared.stats()).bytes);
}
test "configuration ownership exact tuple and ordered responses under every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedFixture, .{});
}
test "configuration requires one JSON value and unique object and routing keys" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.DuplicateField, Prepared.create(a, .{ .settings_json = "{\"x\":1,\"x\":2}" }, .{}));
    try std.testing.expectError(error.SyntaxError, Prepared.create(a, .{ .settings_json = "true false" }, .{}));
    try std.testing.expectError(error.DuplicateConfiguration, Prepared.create(a, .{ .settings_json = "null", .entries = &.{ .{ .value_json = "1" }, .{ .value_json = "2" } } }, .{}));
    var flag: positions.Cancellation = .{};
    flag.request();
    try std.testing.expectError(error.Cancelled, Prepared.create(a, .{ .settings_json = "{}" }, .{ .cancellation = &flag }));
}
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize,
    peak: usize,
    denied: bool = false,
    fn failure(self: *const Budget, err: anyerror) anyerror {
        return if (err == error.OutOfMemory and self.denied) error.ConfigurationCapacityExceeded else err;
    }
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (len > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const memory = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return memory;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ra);
        self.live -= bytes.len;
    }
};
