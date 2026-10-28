const std = @import("std");
const schemes = @import("schemes.zig");

pub const capacity = 8;
pub const origin_capacity = 8;
pub const body_limit = 32 * 1024;
pub const total_body_limit = capacity * body_limit;
pub const total_origin_limit = 8 * 1024;

pub const Timing = enum { document_start, document_end };
pub const Frames = enum { top, all };
pub const World = enum { page, isolated };
/// A trusted, syntactically valid ordinary function body, not a global script
/// or JavaScript module. This wrapper is not an untrusted-code sandbox. Inputs
/// (including their bytes) stay borrowed and stable until the entry point
/// returns; acceptance owns its independent copy. Installation does not certify
/// syntax or execution. The guard/return/throw semantics require a valid body.
pub const Initializer = struct {
    body: []const u8,
    origins: []const []const u8,
    timing: Timing = .document_start,
    frames: Frames = .top,
    world: World = .page,
};

pub const Limits = struct {
    /// Simultaneously live requested framework bytes: owners, original bodies,
    /// descriptors/origins, encoded batches and independent native copies. SDK
    /// private allocations are outside this counter. No historical-work credit.
    bytes: usize = 4 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.bytes == 0 or self.bytes > 8 * 1024 * 1024) return error.InvalidInitializerLimits;
    }
};

/// A stable accounting domain borrowed until retain returns. Every nonempty
/// owner retains it independently through its final free/release callback.
/// Native adapters supply C-only functions; native release never calls Zig or
/// borrows this descriptor. Native copies retain the domain independently too.
pub const Accounting = struct {
    context: *anyopaque,
    retain_fn: *const fn (*anyopaque) callconv(.c) void,
    unref_fn: *const fn (*anyopaque) callconv(.c) void,
    reserve_fn: *const fn (*anyopaque, usize) callconv(.c) bool,
    release_fn: *const fn (*anyopaque, usize) callconv(.c) void,
    pub fn retain(self: Accounting) void {
        self.retain_fn(self.context);
    }
    pub fn unref(self: Accounting) void {
        self.unref_fn(self.context);
    }
    pub fn reserve(self: Accounting, bytes: usize) !void {
        if (!self.reserve_fn(self.context, bytes)) return error.InitializerBudgetExceeded;
    }
    pub fn release(self: Accounting, bytes: usize) void {
        self.release_fn(self.context, bytes);
    }
};

/// Pure owner-thread accounting; the caller keeps the record at a stable
/// address. Its initial reference belongs to the caller. Native adapters use a
/// separately allocated C domain, whose last reference frees the record.
pub const Budget = struct {
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    refs: usize = 1,

    pub fn init(limits: Limits) !Budget {
        try limits.validate();
        return .{ .limit = limits.bytes };
    }
    pub fn reserve(self: *Budget, bytes: usize) !void {
        std.debug.assert(self.refs != 0);
        if (bytes > self.limit or self.used > self.limit - bytes) return error.InitializerBudgetExceeded;
        self.used += bytes;
        self.peak = @max(self.peak, self.used);
    }
    pub fn release(self: *Budget, bytes: usize) void {
        std.debug.assert(self.refs != 0 and bytes <= self.used);
        self.used -= bytes;
    }
    pub fn accounting(self: *Budget) Accounting {
        return .{ .context = self, .retain_fn = retainCallback, .unref_fn = unrefCallback, .reserve_fn = reserveCallback, .release_fn = releaseCallback };
    }
    fn retainCallback(context: *anyopaque) callconv(.c) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        std.debug.assert(self.refs != 0 and self.refs != std.math.maxInt(usize));
        self.refs += 1;
    }
    fn unrefCallback(context: *anyopaque) callconv(.c) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        std.debug.assert(self.refs != 0 or self.used == 0);
    }
    fn reserveCallback(context: *anyopaque, bytes: usize) callconv(.c) bool {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.reserve(bytes) catch return false;
        return true;
    }
    fn releaseCallback(context: *anyopaque, bytes: usize) callconv(.c) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.release(bytes);
    }
};

const alignment = std.mem.Alignment.fromByteUnits(@alignOf(Initializer));

/// Linear immutable owner; move with take, never copy. Source bodies are copied
/// before inspecting their contents or deriving UTF-16. Empty input allocates
/// nothing and does not enter the descriptor-capture frame.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    accounting: Accounting,
    storage: ?[]align(@alignOf(Initializer)) u8 = null,
    entries: []const Initializer = &.{},
    encoded: ?[:0]const u16 = null,
    storage_bytes: usize = 0,
    encoded_bytes: usize = 0,
    owns_context: bool = false,

    pub fn init(allocator: std.mem.Allocator, budget: *Budget, input: []const Initializer) !Owned {
        return initAccounted(allocator, budget.accounting(), input);
    }
    pub fn initAccounted(allocator: std.mem.Allocator, accounting: Accounting, input: []const Initializer) !Owned {
        if (input.len == 0) return .{ .allocator = allocator, .accounting = accounting };
        return initNonEmpty(allocator, accounting, input);
    }
    noinline fn initNonEmpty(allocator: std.mem.Allocator, accounting: Accounting, input: []const Initializer) !Owned {
        if (input.len > capacity) return error.TooManyInitializers;
        // Only bounded descriptors are captured. Caller bytes remain stable
        // borrows until return; no body-sized capture is placed on the stack.
        var captured: [capacity]Initializer = undefined;
        var captured_origins: [capacity][origin_capacity][]const u8 = undefined;
        var origin_count: usize = 0;
        var body_bytes: usize = 0;
        var origin_bytes: usize = 0;
        var canonical_bytes: usize = 0;
        for (input, 0..) |item, index| {
            if (item.timing != .document_start or item.frames != .top or item.world != .page) return error.UnsupportedInitializerCapability;
            if (item.body.len > body_limit) return error.InitializerBodyTooLarge;
            if (item.origins.len == 0 or item.origins.len > origin_capacity) return error.InvalidInitializerOrigins;
            captured[index] = item;
            for (item.origins, 0..) |origin, n| {
                if (origin.len == 0 or origin.len > schemes.origin_limit) return error.InvalidInitializerOrigin;
                captured_origins[index][n] = origin;
                origin_bytes += origin.len;
                // DNS spelling cannot grow during canonicalization; every
                // supported IPv6 HTTPS origin, including port, fits 64 bytes.
                canonical_bytes += @max(origin.len, 64);
            }
            captured[index].origins = captured_origins[index][0..item.origins.len];
            origin_count += item.origins.len;
            body_bytes += item.body.len;
        }
        if (body_bytes > total_body_limit or origin_bytes > total_origin_limit) return error.InitializerInputTooLarge;
        const rows_bytes = input.len * @sizeOf(Initializer);
        const descriptors_bytes = origin_count * @sizeOf([]const u8);
        const raw_bytes = rows_bytes + descriptors_bytes + body_bytes + origin_bytes + canonical_bytes;
        accounting.retain();
        var owned: Owned = .{ .allocator = allocator, .accounting = accounting, .owns_context = true };
        errdefer owned.deinit();
        try accounting.reserve(raw_bytes);
        const storage = allocator.alignedAlloc(u8, alignment, raw_bytes) catch |err| {
            accounting.release(raw_bytes);
            return err;
        };
        owned.storage = storage;
        owned.storage_bytes = raw_bytes;
        const rows = @as([*]Initializer, @ptrCast(storage.ptr))[0..input.len];
        const origins = @as([*][]const u8, @ptrCast(@alignCast(storage.ptr + rows_bytes)))[0..origin_count];
        var cursor = rows_bytes + descriptors_bytes;
        var origin_index: usize = 0;
        for (captured[0..input.len], rows) |item, *row| {
            row.* = item;
            row.body = storage[cursor..][0..item.body.len];
            @memcpy(storage[cursor..][0..item.body.len], item.body);
            cursor += item.body.len;
            row.origins = origins[origin_index..][0..item.origins.len];
            origin_index += item.origins.len;
        }
        // Own all raw origin bytes before any canonicalization reads them.
        origin_index = 0;
        for (captured[0..input.len]) |item| for (item.origins) |origin| {
            @memcpy(storage[cursor..][0..origin.len], origin);
            origins[origin_index] = storage[cursor..][0..origin.len];
            cursor += origin.len;
            origin_index += 1;
        };
        for (rows) |row| {
            if (std.mem.indexOfScalar(u8, row.body, 0) != null) return error.EmbeddedNul;
            if (!std.unicode.utf8ValidateSlice(row.body)) return error.InvalidUtf8;
        }
        origin_index = 0;
        for (rows) |row| {
            for (row.origins, 0..) |raw, index| {
                const room = @max(raw.len, 64);
                const canonical = schemes.canonicalOrigin(storage[cursor..][0..room], raw, &.{}) catch return error.InvalidInitializerOrigin;
                if (!std.mem.startsWith(u8, canonical, "https://")) return error.InvalidInitializerOrigin;
                for (row.origins[0..index]) |earlier| if (std.mem.eql(u8, canonical, earlier)) return error.DuplicateInitializerOrigin;
                origins[origin_index] = canonical;
                origin_index += 1;
                cursor += room;
            }
        }
        std.debug.assert(cursor == storage.len);
        owned.entries = rows;
        const units = try renderBatch(rows, null);
        const wide_bytes = (units + 1) * @sizeOf(u16);
        try accounting.reserve(wide_bytes);
        const wide = allocator.allocSentinel(u16, units, 0) catch |err| {
            accounting.release(wide_bytes);
            return err;
        };
        owned.encoded = wide;
        owned.encoded_bytes = wide_bytes;
        const rendered = try renderBatch(rows, wide);
        std.debug.assert(rendered == units);
        return owned;
    }
    pub fn bytes(self: *const Owned) usize {
        return self.storage_bytes + self.encoded_bytes;
    }
    pub fn take(self: *Owned) Owned {
        const value = self.*;
        self.storage = null;
        self.entries = &.{};
        self.encoded = null;
        self.storage_bytes = 0;
        self.encoded_bytes = 0;
        self.owns_context = false;
        return value;
    }
    pub fn deinit(self: *Owned) void {
        const value = self.take();
        // Withdraw before a foreign free; account the allocation until free
        // actually returns so allocator reentry cannot spend its bytes early.
        if (value.encoded) |wide| {
            value.allocator.free(wide);
            value.accounting.release(value.encoded_bytes);
        }
        if (value.storage) |storage| {
            value.allocator.free(storage);
            value.accounting.release(value.storage_bytes);
        }
        // Foreign frees/releases can close the containing View. This owner's
        // independent pin is the last responsibility withdrawn here.
        if (value.owns_context) value.accounting.unref();
    }
};

const Encoder = struct {
    output: ?[]u16,
    units: usize = 0,
    fn append(self: *Encoder, value: []const u8) !void {
        if (self.output) |output| {
            self.units += try std.unicode.utf8ToUtf16Le(output[self.units..], value);
        } else self.units += try std.unicode.calcUtf16LeLen(value);
    }
};
fn renderBatch(entries: []const Initializer, output: ?[]u16) !usize {
    var encoder: Encoder = .{ .output = output };
    try encoder.append("(()=>{\n");
    for (entries) |entry| {
        // No eval/Function constructors or shared global program concatenation.
        // Re-read the actual document/frame/origin before each separate body.
        try encoder.append("if(window===window.top&&location.protocol==='https:'&&(");
        for (entry.origins, 0..) |origin, index| {
            if (index != 0) try encoder.append("||");
            try encoder.append("location.origin==='");
            try encoder.append(origin);
            try encoder.append("'");
        }
        try encoder.append("))(function(){\n");
        try encoder.append(entry.body);
        try encoder.append("\n})();\n");
    }
    try encoder.append("})();\n");
    return encoder.units;
}

test "empty initializer configuration has no allocation, encoded batch or budget charge" {
    var budget = try Budget.init(.{});
    var owned = try Owned.init(std.testing.failing_allocator, &budget, &.{});
    defer owned.deinit();
    try std.testing.expect(owned.encoded == null and owned.entries.len == 0 and budget.used == 0 and budget.peak == 0 and budget.refs == 1);
}

fn ownedInputs(allocator: std.mem.Allocator) !void {
    var budget = try Budget.init(.{});
    defer std.debug.assert(budget.used == 0 and budget.refs == 1);
    var body = "window.order=(window.order||'')+'甲😀';return;".*;
    var origin = "HTTPS://EXAMPLE.test:443/".*;
    var origins = [_][]const u8{&origin};
    var entries = [_]Initializer{.{ .body = &body, .origins = &origins }};
    var owned = try Owned.init(allocator, &budget, &entries);
    defer owned.deinit();
    @memset(&body, '?');
    @memset(&origin, '?');
    entries[0].body = "throw Error('changed')";
    origins[0] = "https://changed.test";
    try std.testing.expectEqualStrings("https://example.test", owned.entries[0].origins[0]);
    try std.testing.expectEqualStrings("window.order=(window.order||'')+'甲😀';return;", owned.entries[0].body);
    const encoded = try std.unicode.utf16LeToUtf8Alloc(allocator, owned.encoded.?);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "location.origin==='https://example.test'") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "window.order=(window.order||'')+'甲😀';return;") != null);
    try std.testing.expect(budget.used == owned.bytes() and budget.used != 0);
}

test "initializers own bodies and canonical scopes and unwind every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedInputs, .{});
}

test "owned batch rejects capabilities, invalid text and ambiguous or duplicate origins" {
    var budget = try Budget.init(.{});
    const invalid_origins = [_][]const u8{ "http://example.test", "https://example.test/path", "https://user@example.test", "https://*.example.test", "https://127.1", "https://example.test." };
    for (invalid_origins) |origin| try std.testing.expectError(error.InvalidInitializerOrigin, Owned.init(std.testing.allocator, &budget, &.{.{ .body = "", .origins = &.{origin} }}));
    try std.testing.expectError(error.DuplicateInitializerOrigin, Owned.init(std.testing.allocator, &budget, &.{.{ .body = "", .origins = &.{ "https://example.test", "HTTPS://EXAMPLE.test:443/" } }}));
    try std.testing.expectError(error.EmbeddedNul, Owned.init(std.testing.allocator, &budget, &.{.{ .body = "x\x00y", .origins = &.{"https://example.test"} }}));
    try std.testing.expectError(error.InvalidUtf8, Owned.init(std.testing.allocator, &budget, &.{.{ .body = "\xff", .origins = &.{"https://example.test"} }}));
    try std.testing.expectError(error.UnsupportedInitializerCapability, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &.{"https://example.test"}, .world = .isolated }}));
    try std.testing.expectError(error.UnsupportedInitializerCapability, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &.{"https://example.test"}, .timing = .document_end }}));
    try std.testing.expectError(error.UnsupportedInitializerCapability, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &.{"https://example.test"}, .frames = .all }}));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "old candidate encoded and native-copy charges share one simultaneous budget" {
    var budget = try Budget.init(.{});
    var old = try Owned.init(std.testing.allocator, &budget, &.{.{ .body = "window.old=1", .origins = &.{"https://example.test"} }});
    defer old.deinit();
    const native_old = old.encoded_bytes + 128;
    try budget.reserve(native_old);
    defer budget.release(native_old);
    const kept = budget.used;
    budget.limit = kept + old.bytes() - 1;
    try std.testing.expectError(error.InitializerBudgetExceeded, Owned.init(std.testing.allocator, &budget, &.{.{ .body = "window.old=1", .origins = &.{"https://example.test"} }}));
    try std.testing.expectEqual(kept, budget.used);
    budget.limit = kept + old.bytes();
    var candidate = try Owned.init(std.testing.allocator, &budget, &.{.{ .body = "window.old=1", .origins = &.{"https://example.test"} }});
    defer candidate.deinit();
    try std.testing.expectError(error.InitializerBudgetExceeded, budget.reserve(candidate.encoded_bytes));
    try std.testing.expectEqual(budget.limit, budget.used);
}

test "owned withdrawal precedes foreign allocator free and charges stay live through reentry" {
    const Probe = struct {
        owned: ?*Owned = null,
        budget: *Budget,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(_: *anyopaque, length: usize, align_value: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(length, align_value, ra);
        }
        fn free(ptr: *anyopaque, memory: []u8, align_value: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frees += 1;
            if (self.owned) |owned| {
                std.debug.assert(owned.storage == null and owned.encoded == null and owned.entries.len == 0);
                std.debug.assert(self.budget.used >= memory.len);
                owned.deinit();
            }
            std.testing.allocator.rawFree(memory, align_value, ra);
        }
    };
    var budget = try Budget.init(.{});
    var probe: Probe = .{ .budget = &budget };
    var owned = try Owned.init(probe.allocator(), &budget, &.{.{ .body = "// final line comment", .origins = &.{"https://example.test"} }});
    probe.owned = &owned;
    owned.deinit();
    try std.testing.expect(probe.frees == 2 and budget.used == 0);
}

test "an owned accounting reference survives its containing owner closing during free" {
    const Probe = struct {
        budget: *Budget,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(_: *anyopaque, length: usize, align_value: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(length, align_value, ra);
        }
        fn free(context: *anyopaque, memory: []u8, align_value: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.frees += 1;
            if (self.frees == 1) {
                std.debug.assert(self.budget.refs == 2);
                // Models releasing the View's domain pin during allocator
                // reentry. The linear Owned retains its own pin throughout.
                self.budget.accounting().unref();
            }
            std.debug.assert(self.budget.refs == 1 and self.budget.used >= memory.len);
            std.testing.allocator.rawFree(memory, align_value, ra);
        }
    };
    var budget = try Budget.init(.{});
    var probe: Probe = .{ .budget = &budget };
    var owned = try Owned.init(probe.allocator(), &budget, &.{.{ .body = "return;", .origins = &.{"https://example.test"} }});
    try std.testing.expectEqual(@as(usize, 2), budget.refs);
    owned.deinit();
    try std.testing.expect(probe.frees == 2 and budget.used == 0 and budget.refs == 0);
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.refs);
}

test "entry and origin descriptors are captured before the caller allocator can replace them" {
    const Probe = struct {
        entry: *Initializer,
        origins: *[1][]const u8,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(context: *anyopaque, length: usize, align_value: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entry.body = "\xff";
            self.entry.origins = &.{};
            self.origins[0] = "http://changed.test";
            return std.testing.allocator.rawAlloc(length, align_value, ra);
        }
        fn free(_: *anyopaque, memory: []u8, align_value: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(memory, align_value, ra);
        }
    };
    var origins = [_][]const u8{"https://example.test"};
    var entries = [_]Initializer{.{ .body = "window.before=1", .origins = &origins }};
    var probe: Probe = .{ .entry = &entries[0], .origins = &origins };
    var budget = try Budget.init(.{});
    var owned = try Owned.init(probe.allocator(), &budget, &entries);
    defer owned.deinit();
    try std.testing.expectEqualStrings("window.before=1", owned.entries[0].body);
    try std.testing.expectEqualStrings("https://example.test", owned.entries[0].origins[0]);
}

test "initializer hard bounds reject descriptors before any allocation" {
    var budget = try Budget.init(.{});
    const entry: Initializer = .{ .body = "", .origins = &.{"https://example.test"} };
    try std.testing.expectError(error.TooManyInitializers, Owned.init(std.testing.failing_allocator, &budget, &(@as([9]Initializer, @splat(entry)))));
    try std.testing.expectError(error.InvalidInitializerOrigins, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &.{} }}));
    try std.testing.expectError(error.InvalidInitializerOrigins, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &@as([9][]const u8, @splat("https://example.test")) }}));
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    try std.testing.expectError(error.InitializerBodyTooLarge, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = unreadable[0 .. body_limit + 1], .origins = &.{"https://example.test"} }}));
    try std.testing.expectError(error.InvalidInitializerOrigin, Owned.init(std.testing.failing_allocator, &budget, &.{.{ .body = "", .origins = &.{unreadable[0 .. schemes.origin_limit + 1]} }}));
    try std.testing.expectError(error.InvalidInitializerLimits, Budget.init(.{ .bytes = 0 }));
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
