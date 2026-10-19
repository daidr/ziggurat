const std = @import("std");
const locale_mod = @import("locale.zig");
const Locale = locale_mod.Locale;
const message = @import("message.zig");
const pseudo = @import("pseudo.zig");

pub const Entry = struct { key: []const u8, message: []const u8 };

pub const max_key_len = 256;
pub const max_entries = 65536;
pub const max_bundles = 64;
pub const max_json_depth = 8;
pub const max_json_bytes = 16 * 1024 * 1024;

pub const AddError = error{
    OutOfMemory,
    DuplicateLocale,
    DuplicateKey,
    InvalidKey,
    InvalidMessage,
    NestingTooDeep,
    InvalidJson,
    TooManyEntries,
    TooManyBundles,
};

/// Names the entry that failed an add, copied so it outlives the input.
pub const Diagnostic = struct {
    key_buffer: [max_key_len]u8 = undefined,
    key_len: usize = 0,

    pub fn key(self: *const Diagnostic) []const u8 {
        return self.key_buffer[0..self.key_len];
    }
    fn set(self: ?*Diagnostic, value: []const u8) void {
        const d = self orelse return;
        d.key_len = @min(value.len, max_key_len);
        @memcpy(d.key_buffer[0..d.key_len], value[0..d.key_len]);
    }
};

const Bundle = struct {
    locale: Locale,
    /// Sorted by key; owned by `arena` (strings may be borrowed).
    entries: []const Entry,
    arena: std.heap.ArenaAllocator,

    fn find(self: *const Bundle, key: []const u8) ?[]const u8 {
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.entries[mid].key, key)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.entries[mid].message,
            }
        }
        return null;
    }
};

/// Messages per locale. Every message is validated when added, and an
/// add that fails leaves the catalog unchanged. After building, a catalog
/// is read-only and may be shared by Localizers on any thread; adding
/// bundles requires exclusive access.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    /// The language the messages were written in; its chain ends every
    /// Localizer chain.
    source: Locale,
    bundles: std.ArrayList(Bundle) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: Locale) Catalog {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.bundles.items) |*bundle| bundle.arena.deinit();
        self.bundles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn localeCount(self: *const Catalog) usize {
        return self.bundles.items.len;
    }
    pub fn localeAt(self: *const Catalog, index: usize) Locale {
        return self.bundles.items[index].locale;
    }

    /// Adds borrowed entries, typically compile-time constants; the strings
    /// must outlive the catalog. Only the sorted index is allocated.
    pub fn addEntries(self: *Catalog, locale: Locale, entries: []const Entry, diagnostic: ?*Diagnostic) AddError!void {
        try self.checkLocale(locale);
        if (entries.len > max_entries) return error.TooManyEntries;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const sorted = try arena.allocator().dupe(Entry, entries);
        try finish(sorted, diagnostic);
        try self.append(.{ .locale = locale, .entries = sorted, .arena = arena });
    }

    /// Copies messages from a JSON object of strings. Nested objects are
    /// flattened with `.` (`{"menu": {"open": "Open"}}` gives `menu.open`).
    /// Duplicate keys, other value types, depth above 8 and inputs above
    /// 16 MiB are rejected.
    pub fn addJson(self: *Catalog, locale: Locale, json: []const u8, diagnostic: ?*Diagnostic) AddError!void {
        try self.checkLocale(locale);
        if (json.len > max_json_bytes) return error.InvalidJson;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{ .duplicate_field_behavior = .@"error" }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        var entries: std.ArrayList(Entry) = .empty;
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.allocator);
        try flatten(arena.allocator(), self.allocator, &entries, &prefix, parsed.value.object, 0, diagnostic);
        try finish(entries.items, diagnostic);
        try self.append(.{ .locale = locale, .entries = entries.items, .arena = arena });
    }

    /// The pattern stored for exactly this locale, without fallback.
    pub fn lookup(self: *const Catalog, locale: *const Locale, key: []const u8) ?[]const u8 {
        const index = self.bundleIndex(locale) orelse return null;
        return self.bundles.items[index].find(key);
    }

    /// The best catalog locale for the user's ordered preferences, or the
    /// source locale when none matches.
    pub fn negotiate(self: *const Catalog, requested: []const Locale) Locale {
        var available: [max_bundles]Locale = undefined;
        for (self.bundles.items, 0..) |*bundle, i| available[i] = bundle.locale;
        const index = locale_mod.negotiate(requested, available[0..self.bundles.items.len]) orelse return self.source;
        return available[index];
    }

    fn bundleIndex(self: *const Catalog, locale: *const Locale) ?usize {
        for (self.bundles.items, 0..) |*bundle, i| if (bundle.locale.eql(locale)) return i;
        return null;
    }

    fn checkLocale(self: *const Catalog, locale: Locale) AddError!void {
        if (self.bundleIndex(&locale) != null) return error.DuplicateLocale;
        if (self.bundles.items.len >= max_bundles) return error.TooManyBundles;
    }

    fn append(self: *Catalog, bundle: Bundle) AddError!void {
        try self.bundles.append(self.allocator, bundle);
    }
};

fn flatten(arena: std.mem.Allocator, scratch: std.mem.Allocator, entries: *std.ArrayList(Entry), prefix: *std.ArrayList(u8), object: std.json.ObjectMap, depth: usize, diagnostic: ?*Diagnostic) AddError!void {
    if (depth >= max_json_depth) return error.NestingTooDeep;
    var iterator = object.iterator();
    while (iterator.next()) |item| {
        const restore = prefix.items.len;
        defer prefix.shrinkRetainingCapacity(restore);
        if (restore > 0) try prefix.append(scratch, '.');
        try prefix.appendSlice(scratch, item.key_ptr.*);
        if (prefix.items.len > max_key_len) {
            Diagnostic.set(diagnostic, prefix.items);
            return error.InvalidKey;
        }
        switch (item.value_ptr.*) {
            .string => |text| {
                if (entries.items.len >= max_entries) return error.TooManyEntries;
                try entries.append(arena, .{ .key = try arena.dupe(u8, prefix.items), .message = try arena.dupe(u8, text) });
            },
            .object => |child| try flatten(arena, scratch, entries, prefix, child, depth + 1, diagnostic),
            else => {
                Diagnostic.set(diagnostic, prefix.items);
                return error.InvalidJson;
            },
        }
    }
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn finish(entries: []Entry, diagnostic: ?*Diagnostic) AddError!void {
    for (entries) |entry| {
        if (entry.key.len == 0 or entry.key.len > max_key_len or !std.unicode.utf8ValidateSlice(entry.key)) {
            Diagnostic.set(diagnostic, entry.key);
            return error.InvalidKey;
        }
        for (entry.key) |c| if (c < 0x20 or c == 0x7f) {
            Diagnostic.set(diagnostic, entry.key);
            return error.InvalidKey;
        };
        if (!std.unicode.utf8ValidateSlice(entry.message)) {
            Diagnostic.set(diagnostic, entry.key);
            return error.InvalidMessage;
        }
        message.validate(entry.message) catch |err| {
            Diagnostic.set(diagnostic, entry.key);
            return switch (err) {
                error.NestingTooDeep => error.NestingTooDeep,
                else => error.InvalidMessage,
            };
        };
    }
    std.mem.sort(Entry, entries, {}, lessThan);
    if (entries.len < 2) return;
    for (entries[1..], 0..) |entry, i| if (std.mem.eql(u8, entry.key, entries[i].key)) {
        Diagnostic.set(diagnostic, entry.key);
        return error.DuplicateKey;
    };
}

/// Validates compile-time entries so a bad message fails the build.
pub fn comptimeValidate(comptime entries: []const Entry) void {
    inline for (entries) |entry| message.comptimeValidate(entry.message);
}

pub const Missing = enum {
    /// Write the key itself so the gap is visible in the interface.
    key,
    fail,
};

pub const LocalizerOptions = struct {
    /// Null selects from the locale: `XA` accented and `XB` bidi.
    pseudo: ?pseudo.Mode = null,
    isolate_arguments: bool = true,
    missing: Missing = .key,
};

pub const FormatError = message.Error || error{MissingMessage};

pub const Resolved = struct { pattern: []const u8, locale: Locale };

/// A display locale bound to a catalog: the bundle chain is resolved once
/// and each format is a binary search per chain entry plus formatting into
/// the caller's writer, with no allocation. A message found on the display
/// locale's own chain is formatted with the display locale (de-CH numbers
/// in a de message); a message from the source fallback uses the source
/// bundle's locale for plural rules, numbers and dates.
/// The catalog must outlive the Localizer; bundles added later are not in
/// its chain.
pub const Localizer = struct {
    catalog: *const Catalog,
    locale: Locale,
    chain: [locale_mod.max_chain * 2]u8 = undefined,
    chain_len: usize = 0,
    /// Chain entries before this index come from the display locale's own
    /// chain; later ones from the source locale's.
    own_len: usize = 0,
    pseudo: pseudo.Mode,
    isolate_arguments: bool,
    missing: Missing,

    pub fn init(catalog: *const Catalog, locale: Locale, options: LocalizerOptions) Localizer {
        var self: Localizer = .{
            .catalog = catalog,
            .locale = locale,
            .pseudo = options.pseudo orelse pseudo.modeFor(&locale),
            .isolate_arguments = options.isolate_arguments,
            .missing = options.missing,
        };
        // Pseudolocales render the source messages.
        if (self.pseudo == .none or catalog.bundleIndex(&locale) != null) self.addChain(&locale);
        self.own_len = self.chain_len;
        self.addChain(&catalog.source);
        return self;
    }

    fn addChain(self: *Localizer, locale: *const Locale) void {
        const chain = locale.fallbackChain();
        for (chain.slice()) |*candidate| {
            const index = self.catalog.bundleIndex(candidate) orelse continue;
            if (std.mem.indexOfScalar(u8, self.chain[0..self.chain_len], @intCast(index)) != null) continue;
            self.chain[self.chain_len] = @intCast(index);
            self.chain_len += 1;
        }
    }

    pub fn direction(self: *const Localizer) locale_mod.Direction {
        return if (self.pseudo == .bidi) .rtl else self.locale.direction();
    }

    pub fn resolve(self: *const Localizer, key: []const u8) ?Resolved {
        for (self.chain[0..self.chain_len], 0..) |index, position| {
            const bundle = &self.catalog.bundles.items[index];
            const pattern = bundle.find(key) orelse continue;
            return .{ .pattern = pattern, .locale = if (position < self.own_len) self.locale else bundle.locale };
        }
        return null;
    }

    pub fn has(self: *const Localizer, key: []const u8) bool {
        return self.resolve(key) != null;
    }

    pub fn format(self: *const Localizer, writer: *std.Io.Writer, key: []const u8, arguments: []const message.Arg) FormatError!void {
        const resolved = self.resolve(key) orelse return switch (self.missing) {
            .key => writer.writeAll(key),
            .fail => error.MissingMessage,
        };
        try message.format(writer, &resolved.locale, resolved.pattern, arguments, .{
            .pseudo = self.pseudo,
            .isolate_arguments = self.isolate_arguments,
        });
    }

    /// Formats into `buffer`; `WriteFailed` means it was too small.
    pub fn bufPrint(self: *const Localizer, buffer: []u8, key: []const u8, arguments: []const message.Arg) FormatError![]const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        try self.format(&writer, key, arguments);
        return writer.buffered();
    }

    /// Formats into memory from `allocator`, owned by the caller.
    pub fn allocPrint(self: *const Localizer, allocator: std.mem.Allocator, key: []const u8, arguments: []const message.Arg) (FormatError || error{OutOfMemory})![]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        self.format(&writer.writer, key, arguments) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => |other| other,
        };
        return writer.toOwnedSlice();
    }
};

const english = [_]Entry{
    .{ .key = "app.title", .message = "Notes" },
    .{ .key = "files", .message = "{count, plural, one {# file} other {# files}}" },
    .{ .key = "greeting", .message = "Hello, {name}!" },
    .{ .key = "only.english", .message = "English only" },
};
comptime {
    comptimeValidate(&english);
}

test "fallback through locale chain and source" {
    const testing = std.testing;
    var catalog = Catalog.init(testing.allocator, try Locale.parse("en"));
    defer catalog.deinit();
    try catalog.addEntries(try Locale.parse("en"), &english, null);
    try catalog.addJson(try Locale.parse("de"),
        \\{"app": {"title": "Notizen"}, "files": "{count, plural, one {# Datei} other {# Dateien}}"}
    , null);
    try catalog.addJson(try Locale.parse("de-CH"), "{\"greeting\": \"Grüezi {name}!\"}", null);
    const localizer = Localizer.init(&catalog, try Locale.parse("de-CH"), .{});
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("Grüezi Ana!", try localizer.bufPrint(&buffer, "greeting", &message.args(.{ .name = "Ana" })));
    try testing.expectEqualStrings("Notizen", try localizer.bufPrint(&buffer, "app.title", &.{}));
    try testing.expectEqualStrings("1’200 Dateien", try localizer.bufPrint(&buffer, "files", &message.args(.{ .count = 1200 })));
    try testing.expectEqualStrings("English only", try localizer.bufPrint(&buffer, "only.english", &.{}));
    try testing.expectEqualStrings("absent.key", try localizer.bufPrint(&buffer, "absent.key", &.{}));
    const strict = Localizer.init(&catalog, try Locale.parse("de"), .{ .missing = .fail });
    try testing.expectError(error.MissingMessage, strict.bufPrint(&buffer, "absent.key", &.{}));
    try testing.expectEqualStrings("1.200 Dateien", try strict.bufPrint(&buffer, "files", &message.args(.{ .count = 1200 })));
    const owned = try strict.allocPrint(testing.allocator, "app.title", &.{});
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("Notizen", owned);
    try testing.expectEqualStrings("Notizen", catalog.lookup(&(try Locale.parse("de")), "app.title").?);
    try testing.expect(catalog.lookup(&(try Locale.parse("de-CH")), "app.title") == null);
}

test "negotiation and pseudolocales" {
    const testing = std.testing;
    var catalog = Catalog.init(testing.allocator, try Locale.parse("en"));
    defer catalog.deinit();
    try catalog.addEntries(try Locale.parse("en"), &english, null);
    try catalog.addJson(try Locale.parse("fr"), "{\"app.title\": \"Notes (fr)\"}", null);
    const requested = [_]Locale{ try Locale.parse("ja-JP"), try Locale.parse("fr-CA") };
    try testing.expectEqualStrings("fr", catalog.negotiate(&requested).tag());
    try testing.expectEqualStrings("en", catalog.negotiate(&.{try Locale.parse("ja")}).tag());
    var buffer: [128]u8 = undefined;
    const xa = Localizer.init(&catalog, try Locale.parse("en-XA"), .{});
    try testing.expectEqualStrings("[Ĥéļļö, Kim! ~~~~]", try xa.bufPrint(&buffer, "greeting", &message.args(.{ .name = "Kim" })));
    const xb = Localizer.init(&catalog, try Locale.parse("ar-XB"), .{});
    try testing.expectEqual(locale_mod.Direction.rtl, xb.direction());
    try testing.expectEqualStrings("\u{200F}\u{202E}Notes\u{202C}\u{200F}", try xb.bufPrint(&buffer, "app.title", &.{}));
    const plain = Localizer.init(&catalog, try Locale.parse("en-XA"), .{ .pseudo = .none });
    try testing.expectEqualStrings("Notes", try plain.bufPrint(&buffer, "app.title", &.{}));
}

test "rejected adds leave the catalog unchanged" {
    const testing = std.testing;
    var catalog = Catalog.init(testing.allocator, try Locale.parse("en"));
    defer catalog.deinit();
    var diagnostic: Diagnostic = .{};
    const fr = try Locale.parse("fr");
    try testing.expectError(error.InvalidMessage, catalog.addJson(fr, "{\"ok\": \"fine\", \"bad\": \"{oops\"}", &diagnostic));
    try testing.expectEqualStrings("bad", diagnostic.key());
    try testing.expectError(error.InvalidJson, catalog.addJson(fr, "{\"n\": 3}", &diagnostic));
    try testing.expectEqualStrings("n", diagnostic.key());
    try testing.expectError(error.InvalidJson, catalog.addJson(fr, "{\"a\": \"x\", \"a\": \"y\"}", null));
    try testing.expectError(error.InvalidJson, catalog.addJson(fr, "[\"x\"]", null));
    try testing.expectError(error.InvalidJson, catalog.addJson(fr, "{", null));
    try testing.expectError(error.DuplicateKey, catalog.addJson(fr, "{\"a.b\": \"x\", \"a\": {\"b\": \"y\"}}", &diagnostic));
    try testing.expectEqualStrings("a.b", diagnostic.key());
    try testing.expectError(error.NestingTooDeep, catalog.addJson(fr, "{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":{\"g\":{\"h\":{\"i\":\"x\"}}}}}}}}}", null));
    try testing.expectError(error.InvalidKey, catalog.addEntries(fr, &.{.{ .key = "", .message = "x" }}, null));
    try testing.expectError(error.InvalidKey, catalog.addEntries(fr, &.{.{ .key = "a\nb", .message = "x" }}, null));
    try testing.expectError(error.InvalidMessage, catalog.addEntries(fr, &.{.{ .key = "a", .message = "\xff" }}, null));
    try testing.expectEqual(@as(usize, 0), catalog.localeCount());
    try catalog.addJson(fr, "{}", null);
    try testing.expectError(error.DuplicateLocale, catalog.addJson(fr, "{}", null));
    try testing.expectEqual(@as(usize, 1), catalog.localeCount());
}

test "allocation failures are reported without leaks" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var catalog = Catalog.init(allocator, try Locale.parse("en"));
            defer catalog.deinit();
            try catalog.addEntries(try Locale.parse("en"), &english, null);
            try catalog.addJson(try Locale.parse("de"), "{\"menu\": {\"open\": \"Öffnen\", \"close\": \"Schließen\"}}", null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}
