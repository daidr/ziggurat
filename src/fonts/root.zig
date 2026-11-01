//! Font families for text: the application's own fonts, registered from
//! TrueType or OpenType data (or a collection), and the system's families,
//! as a font setting lists them. A `Font` names its family by a small id
//! this module hands out, which the renderers and text layout resolve to the
//! family name the system knows; registered fonts resolve to their own name
//! when the application registered them under another.
//!
//! Linux adds a registered font to fontconfig's application fonts and tells
//! Pango's font maps; Windows adds it for GDI with AddFontMemResourceEx and
//! for DirectWrite as a font set beside the system's. Both read the font from
//! a file in the user's cache directory, named by a hash of its data.
//!
//! Everything here runs on the process main thread.
const std = @import("std");
const builtin = @import("builtin");
pub const sfnt = @import("sfnt.zig");

const Allocator = std.mem.Allocator;

/// The ids `family` hands out: 1 to 63; 0 is the interface family, or the
/// fixed-pitch one for monospace text.
pub const Id = u8;
pub const max_families = 63;
pub const max_name_bytes = 127;

pub const FontFamily = struct {
    /// The family as `family` takes it.
    name: []const u8,
    /// Whether its regular font gives every character the same advance.
    monospaced: bool,
    /// Whether the application registered it, under `name`.
    registered: bool,
};

const native = switch (builtin.os.tag) {
    // The file cache and family listing are shared; each links its own
    // native registration (fontconfig, Core Text).
    .linux, .macos => @import("linux.zig"),
    .windows => @import("windows.zig"),
    else => @import("unsupported.zig"),
};

const Entry = struct {
    /// Both names end with a NUL, for the native APIs.
    name: [max_name_bytes + 1]u8 = undefined,
    name_len: u8 = 0,
    /// The family the system knows the font by, for a registered one.
    own: [max_name_bytes + 1]u8 = undefined,
    own_len: u8 = 0,
    registered: bool = false,
    monospaced: bool = false,

    fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
    fn ownSlice(self: *const Entry) [:0]const u8 {
        return if (self.own_len > 0) self.own[0..self.own_len :0] else self.name[0..self.name_len :0];
    }
};

var entries: [max_families + 1]Entry = @splat(.{});
var count: usize = 0;
var registered_order: [max_families]Id = undefined;
var registered_count: usize = 0;
/// Hashes of the data registered, so that registering it again only adds
/// its name.
var hashes: [max_families][16]u8 = undefined;
var hash_count: usize = 0;
var changes: u64 = 0;

/// The id of the family `name`, registered or the system's, the same id for
/// the same name whatever its case. The empty name is 0.
pub fn family(family_name: []const u8) !Id {
    if (family_name.len == 0) return 0;
    if (family_name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(family_name) or std.mem.indexOfScalar(u8, family_name, 0) != null) return error.InvalidFamily;
    for (entries[1 .. count + 1], 1..) |*entry, id| if (std.ascii.eqlIgnoreCase(entry.nameSlice(), family_name)) return @intCast(id);
    if (count == max_families) return error.TooManyFamilies;
    count += 1;
    const entry = &entries[count];
    entry.* = .{ .name_len = @intCast(family_name.len) };
    @memcpy(entry.name[0..family_name.len], family_name);
    entry.name[family_name.len] = 0;
    return @intCast(count);
}

/// The name `family` was given for `id`; empty for 0 or an id not handed out.
pub fn name(id: Id) []const u8 {
    if (id == 0 or id > count) return "";
    return entries[id].nameSlice();
}

/// The family name to give the system for `id`: a registered font's own
/// name, or the name itself; empty for 0.
pub fn systemName(id: Id) [:0]const u8 {
    if (id == 0 or id > count) return "";
    return entries[id].ownSlice();
}

/// The family name to give the system for a family named `name`.
pub fn resolve(family_name: []const u8) []const u8 {
    for (entries[1 .. count + 1]) |*entry| if (entry.registered and std.ascii.eqlIgnoreCase(entry.nameSlice(), family_name)) return entry.ownSlice();
    return family_name;
}

/// Counts registrations; text layouts that cache fonts compare it.
pub fn generation() u64 {
    return changes;
}

/// Adds a TrueType or OpenType font, or collection, that text can use with
/// the id returned, under `family_name`, or the font's own family name when
/// it is empty. A collection registered without a name adds each of its
/// families; the id is its first.
pub fn register(allocator: Allocator, data: []const u8, family_name: []const u8) !Id {
    var own_buffer: [8][max_name_bytes]u8 = undefined;
    var own_lens: [8]usize = undefined;
    const faces = try sfnt.families(data, &own_buffer, &own_lens);
    if (faces.count == 0) return error.NoFamilyName;
    if (family_name.len > max_name_bytes) return error.InvalidFamily;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hash = digest[0..16].*;
    var known = false;
    for (hashes[0..hash_count]) |h| if (std.mem.eql(u8, &h, &hash)) {
        known = true;
    };
    // Every name is checked for room before the system takes the font.
    const names_needed: usize = if (family_name.len > 0) 1 else faces.count;
    if (registered_count + names_needed > max_families or (!known and hash_count == max_families)) return error.TooManyFamilies;
    if (!known) {
        try native.add(allocator, data, &hash);
        hashes[hash_count] = hash;
        hash_count += 1;
        changes += 1;
    }
    var first: ?Id = null;
    for (0..names_needed) |at| {
        const own = own_buffer[if (family_name.len > 0) 0 else at][0..own_lens[if (family_name.len > 0) 0 else at]];
        const id = try family(if (family_name.len > 0) family_name else own);
        const entry = &entries[id];
        entry.own_len = @intCast(own.len);
        @memcpy(entry.own[0..own.len], own);
        entry.own[own.len] = 0;
        entry.monospaced = faces.monospaced;
        if (!entry.registered) {
            entry.registered = true;
            registered_order[registered_count] = id;
            registered_count += 1;
        }
        if (first == null) first = id;
    }
    return first.?;
}

/// The font families text can use, as a font setting offers them: the
/// application's registered ones first, then the system's, each once, sorted
/// without regard to case. A font registered under a name the application
/// gave is listed under that name alone. Free with `freeFamilies`.
pub fn families(allocator: Allocator) ![]FontFamily {
    var list: std.ArrayList(FontFamily) = .empty;
    errdefer freeList(allocator, &list);
    for (registered_order[0..registered_count]) |id| {
        const entry = &entries[id];
        try list.ensureUnusedCapacity(allocator, 1);
        list.appendAssumeCapacity(.{ .name = try allocator.dupe(u8, entry.nameSlice()), .monospaced = entry.monospaced, .registered = true });
    }
    const registered_end = list.items.len;
    var system = try native.systemFamilies(allocator);
    defer system.deinit(allocator);
    outer: for (system.items) |item| {
        for (registered_order[0..registered_count]) |id| if (std.ascii.eqlIgnoreCase(entries[id].ownSlice(), item.name) or std.ascii.eqlIgnoreCase(entries[id].nameSlice(), item.name)) continue :outer;
        for (list.items[registered_end..]) |existing| if (std.ascii.eqlIgnoreCase(existing.name, item.name)) continue :outer;
        try list.ensureUnusedCapacity(allocator, 1);
        list.appendAssumeCapacity(.{ .name = try allocator.dupe(u8, item.name), .monospaced = item.monospaced, .registered = false });
    }
    const Order = struct {
        fn less(_: void, a: FontFamily, b: FontFamily) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    };
    std.mem.sort(FontFamily, list.items[0..registered_end], {}, Order.less);
    std.mem.sort(FontFamily, list.items[registered_end..], {}, Order.less);
    return list.toOwnedSlice(allocator);
}

pub fn freeFamilies(allocator: Allocator, list: []FontFamily) void {
    for (list) |item| allocator.free(item.name);
    allocator.free(list);
}

fn freeList(allocator: Allocator, list: *std.ArrayList(FontFamily)) void {
    for (list.items) |item| allocator.free(item.name);
    list.deinit(allocator);
}

/// A system family as the platform lists it; `name` borrows the list.
pub const SystemFamily = struct { name: []const u8, monospaced: bool };

/// Forgets every family and registration record, for tests; the system
/// keeps the fonts it was given.
pub fn resetForTesting() void {
    entries = @splat(.{});
    count = 0;
    registered_count = 0;
    hash_count = 0;
}

test "family ids are stable, case-insensitive and bounded" {
    resetForTesting();
    defer resetForTesting();
    try std.testing.expectEqual(@as(Id, 0), try family(""));
    const serif = try family("Georgia");
    try std.testing.expectEqual(serif, try family("georgia"));
    try std.testing.expectEqualStrings("Georgia", name(serif));
    try std.testing.expectEqualStrings("Georgia", systemName(serif));
    try std.testing.expectEqualStrings("Unknown", resolve("Unknown"));
    try std.testing.expectError(error.InvalidFamily, family("a\x00b"));
    var buffer: [8]u8 = undefined;
    for (count..max_families) |at| _ = try family(try std.fmt.bufPrint(&buffer, "f{d}", .{at}));
    try std.testing.expectError(error.TooManyFamilies, family("one more"));
    try std.testing.expectEqual(serif, try family("GEORGIA"));
}

test {
    _ = sfnt;
    _ = @import("files.zig");
}
