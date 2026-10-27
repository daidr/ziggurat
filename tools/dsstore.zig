//! The .DS_Store file that lays out the Finder window of a disk image:
//! window bounds, icon size and icon positions. Finder reads it when the
//! image is opened, so building the image needs no AppleScript and no
//! Finder automation permission, and works headless. The file is the one
//! the `ds_store` Python package (dmgbuild) writes for the same records,
//! byte for byte: a layout Finder is known to honor.
const std = @import("std");

/// One .DS_Store record: a property (`code`) of a file in the folder, or of
/// the folder itself when `name` is ".".
pub const Record = struct {
    name: []const u8,
    code: *const [4]u8,
    value: Value,

    pub const Value = union(enum) {
        long: u32,
        blob: []const u8,
        type: *const [4]u8,
    };
};

/// A value of a flat binary property list.
pub const PlistValue = union(enum) {
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8,
};

pub const PlistEntry = struct { key: []const u8, value: PlistValue };

/// Places the center of a file's icon, in points from the top-left corner
/// of the window content.
pub fn iconLocation(allocator: std.mem.Allocator, name: []const u8, x: u32, y: u32) !Record {
    const bytes = try allocator.alloc(u8, 16);
    std.mem.writeInt(u32, bytes[0..4], x, .big);
    std.mem.writeInt(u32, bytes[4..8], y, .big);
    @memcpy(bytes[8..16], &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0 });
    return .{ .name = name, .code = "Iloc", .value = .{ .blob = bytes } };
}

fn appendUtf16Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !usize {
    var units: usize = 0;
    var view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x10000) {
            const value = codepoint - 0x10000;
            for ([_]u16{ @intCast(0xd800 + (value >> 10)), @intCast(0xdc00 + (value & 0x3ff)) }) |unit| {
                try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, unit)));
                units += 1;
            }
        } else {
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(codepoint))));
            units += 1;
        }
    }
    return units;
}

fn utf16Length(text: []const u8) !usize {
    var units: usize = 0;
    var view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| units += if (codepoint >= 0x10000) 2 else 1;
    return units;
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(T, value)));
}

fn encodeRecord(allocator: std.mem.Allocator, out: *std.ArrayList(u8), record: Record) !void {
    try appendInt(allocator, out, u32, @intCast(try utf16Length(record.name)));
    _ = try appendUtf16Be(allocator, out, record.name);
    try out.appendSlice(allocator, record.code);
    switch (record.value) {
        .long => |value| {
            try out.appendSlice(allocator, "long");
            try appendInt(allocator, out, u32, value);
        },
        .blob => |bytes| {
            try out.appendSlice(allocator, "blob");
            try appendInt(allocator, out, u32, @intCast(bytes.len));
            try out.appendSlice(allocator, bytes);
        },
        .type => |code| {
            try out.appendSlice(allocator, "type");
            try out.appendSlice(allocator, code);
        },
    }
}

fn lessRecord(_: void, a: Record, b: Record) bool {
    const order = std.ascii.orderIgnoreCase(a.name, b.name);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, a.code, b.code) == .lt;
}

/// Encodes a .DS_Store file holding `records`.
///
/// The file is a buddy-allocated address space (after a 4-byte prefix) with
/// a header at 0, the B-tree header ("DSDB") at 0x20, the allocator's root
/// block at 0x800 and a single B-tree leaf at 0x2000. The records must fit
/// in that leaf, which is plenty for the few records of a disk image window.
pub fn encode(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    const sorted = try allocator.dupe(Record, records);
    defer allocator.free(sorted);
    std.sort.insertion(Record, sorted, {}, lessRecord);

    var node: std.ArrayList(u8) = .empty;
    defer node.deinit(allocator);
    try appendInt(allocator, &node, u32, 0); // a leaf: no child pointer
    try appendInt(allocator, &node, u32, @intCast(sorted.len));
    for (sorted) |record| try encodeRecord(allocator, &node, record);
    const page_size = 0x1000;
    if (node.items.len > page_size) return error.DsStoreRecordsTooLarge;

    const dsdb_address = 0x20; // block 1, 2^5 bytes
    const root_address = 0x800; // block 0, 2^11 bytes
    const node_address = 0x2000; // block 2, 2^13 bytes
    const file = try allocator.alloc(u8, 4 + 0x4000);
    @memset(file, 0);
    file[3] = 1;
    const memory = file[4..]; // allocator addresses are relative to this
    const put = struct {
        fn put(bytes: []u8, offset: usize, value: u32) void {
            std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
        }
    }.put;

    @memcpy(memory[0..4], "Bud1");
    put(memory, 4, root_address);
    put(memory, 8, 0x800); // root block size
    put(memory, 12, root_address);
    @memcpy(memory[16..32], &[_]u8{ 0, 0, 0x10, 0x0c, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0b, 0, 0, 0, 0 });

    put(memory, dsdb_address, 2); // root node: block 2
    put(memory, dsdb_address + 4, 0);
    put(memory, dsdb_address + 8, @intCast(sorted.len));
    put(memory, dsdb_address + 12, 1); // nodes
    put(memory, dsdb_address + 16, page_size);

    const root = memory[root_address..];
    put(root, 0, 3); // blocks
    // Each block is an offset with its log2 size.
    for ([_]u32{ root_address | 11, dsdb_address | 5, node_address | 13 }, 0..) |address, index| put(root, 8 + 4 * index, address);
    var p: usize = 8 + 256 * 4; // the block list is padded to 256 entries
    put(root, p, 1);
    root[p + 4] = 4;
    @memcpy(root[p + 5 .. p + 9], "DSDB");
    put(root, p + 9, 1); // the B-tree header is block 1
    p += 13;
    // Free lists by log2 size. Carving the blocks above out of the initial
    // 2 GiB leaves one free block of each other size at an offset equal to
    // its size.
    for (0..32) |width| {
        if (width < 6 or width == 11 or width == 13 or width == 31) {
            p += 4;
            continue;
        }
        put(root, p, 1);
        put(root, p + 4, @as(u32, 1) << @intCast(width));
        p += 8;
    }

    @memcpy(memory[node_address..][0..node.items.len], node.items);
    return file;
}

fn sizeFor(count: u64) u8 {
    if (count < 1 << 8) return 1;
    if (count < 1 << 16) return 2;
    if (count < 1 << 32) return 4;
    return 8;
}

fn appendUint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64, size: u8) !void {
    var index = size;
    while (index > 0) {
        index -= 1;
        try out.append(allocator, @truncate(value >> @intCast(8 * @as(u32, index))));
    }
}

fn appendPlistInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i64) !void {
    if (value < 0) {
        try out.append(allocator, 0x13);
        return appendUint(allocator, out, @bitCast(value), 8);
    }
    const unsigned: u64 = @intCast(value);
    if (unsigned < 1 << 8) {
        try out.appendSlice(allocator, &.{ 0x10, @intCast(unsigned) });
    } else if (unsigned < 1 << 16) {
        try out.append(allocator, 0x11);
        try appendUint(allocator, out, unsigned, 2);
    } else if (unsigned < 1 << 32) {
        try out.append(allocator, 0x12);
        try appendUint(allocator, out, unsigned, 4);
    } else {
        try out.append(allocator, 0x13);
        try appendUint(allocator, out, unsigned, 8);
    }
}

fn appendPlistSize(allocator: std.mem.Allocator, out: *std.ArrayList(u8), marker: u8, count: usize) !void {
    if (count < 15) return out.append(allocator, marker | @as(u8, @intCast(count)));
    try out.append(allocator, marker | 0xf);
    try appendPlistInt(allocator, out, @intCast(count));
}

fn samePlistValue(a: PlistValue, b: PlistValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .boolean => |value| value == b.boolean,
        .integer => |value| value == b.integer,
        .real => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(b.real)),
        .string => |value| std.mem.eql(u8, value, b.string),
    };
}

fn lessEntry(_: void, a: PlistEntry, b: PlistEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// Encodes a flat dictionary as a binary property list, laid out as
/// Python's plistlib lays it out: the dictionary, then its keys and values
/// by key, with equal scalars written once.
pub fn binaryPlist(allocator: std.mem.Allocator, entries: []const PlistEntry) ![]u8 {
    const sorted = try allocator.dupe(PlistEntry, entries);
    defer allocator.free(sorted);
    std.sort.insertion(PlistEntry, sorted, {}, lessEntry);

    var objects: std.ArrayList(PlistValue) = .empty;
    defer objects.deinit(allocator);
    const references = try allocator.alloc(usize, sorted.len * 2);
    defer allocator.free(references);
    for (0..sorted.len * 2) |index| {
        const value: PlistValue = if (index < sorted.len) .{ .string = sorted[index].key } else sorted[index - sorted.len].value;
        const found = for (objects.items, 0..) |object, at| {
            if (samePlistValue(object, value)) break at;
        } else null;
        if (found) |at| {
            references[index] = at + 1;
        } else {
            try objects.append(allocator, value);
            references[index] = objects.items.len; // the dictionary is object 0
        }
    }
    const count = objects.items.len + 1;
    const reference_size = sizeFor(count);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "bplist00");
    const offsets = try allocator.alloc(u64, count);
    defer allocator.free(offsets);
    offsets[0] = out.items.len;
    try appendPlistSize(allocator, &out, 0xd0, sorted.len);
    for (references) |reference| try appendUint(allocator, &out, reference, reference_size);
    for (objects.items, 1..) |object, index| {
        offsets[index] = out.items.len;
        switch (object) {
            .boolean => |value| try out.append(allocator, if (value) 0x09 else 0x08),
            .integer => |value| try appendPlistInt(allocator, &out, value),
            .real => |value| {
                try out.append(allocator, 0x23);
                try appendUint(allocator, &out, @bitCast(value), 8);
            },
            .string => |value| {
                const ascii = for (value) |byte| {
                    if (byte >= 0x80) break false;
                } else true;
                if (ascii) {
                    try appendPlistSize(allocator, &out, 0x50, value.len);
                    try out.appendSlice(allocator, value);
                } else {
                    try appendPlistSize(allocator, &out, 0x60, try utf16Length(value));
                    _ = try appendUtf16Be(allocator, &out, value);
                }
            },
        }
    }
    const table_offset = out.items.len;
    const offset_size = sizeFor(table_offset);
    for (offsets) |offset| try appendUint(allocator, &out, offset, offset_size);
    try out.appendSlice(allocator, &.{ 0, 0, 0, 0, 0, 0, offset_size, reference_size });
    try appendUint(allocator, &out, count, 8);
    try appendUint(allocator, &out, 0, 8); // the top object
    try appendUint(allocator, &out, table_offset, 8);
    return out.toOwnedSlice(allocator);
}

/// The Finder window of disk images: the app on the left, a link to
/// /Applications on the right.
pub const window = struct {
    /// The bottom-left corner, from the bottom of the screen.
    pub const x = 200;
    pub const y = 400;
    pub const width = 660;
    pub const height = 400;
    pub const icon_size = 128;
    pub const app_x = 180;
    pub const app_y = 190;
    pub const applications_x = 480;
    pub const applications_y = 185;
};

/// The records of the window of a disk image holding `app` (the bundle's
/// file name) and an Applications link.
pub fn dmgRecords(allocator: std.mem.Allocator, app: []const u8) ![6]Record {
    const bounds = try std.fmt.allocPrint(allocator, "{{{{{d}, {d}}}, {{{d}, {d}}}}}", .{ window.x, window.y, window.width, window.height });
    const bwsp = try binaryPlist(allocator, &.{
        .{ .key = "ShowStatusBar", .value = .{ .boolean = false } },
        .{ .key = "WindowBounds", .value = .{ .string = bounds } },
        .{ .key = "ContainerShowSidebar", .value = .{ .boolean = false } },
        .{ .key = "PreviewPaneVisibility", .value = .{ .boolean = false } },
        .{ .key = "SidebarWidth", .value = .{ .integer = 180 } },
        .{ .key = "ShowTabView", .value = .{ .boolean = false } },
        .{ .key = "ShowToolbar", .value = .{ .boolean = false } },
        .{ .key = "ShowPathbar", .value = .{ .boolean = false } },
        .{ .key = "ShowSidebar", .value = .{ .boolean = false } },
    });
    const icvp = try binaryPlist(allocator, &.{
        .{ .key = "viewOptionsVersion", .value = .{ .integer = 1 } },
        .{ .key = "backgroundType", .value = .{ .integer = 0 } },
        .{ .key = "backgroundColorRed", .value = .{ .real = 1 } },
        .{ .key = "backgroundColorGreen", .value = .{ .real = 1 } },
        .{ .key = "backgroundColorBlue", .value = .{ .real = 1 } },
        .{ .key = "gridOffsetX", .value = .{ .real = 0 } },
        .{ .key = "gridOffsetY", .value = .{ .real = 0 } },
        .{ .key = "gridSpacing", .value = .{ .real = 100 } },
        .{ .key = "arrangeBy", .value = .{ .string = "none" } },
        .{ .key = "showIconPreview", .value = .{ .boolean = false } },
        .{ .key = "showItemInfo", .value = .{ .boolean = false } },
        .{ .key = "labelOnBottom", .value = .{ .boolean = true } },
        .{ .key = "textSize", .value = .{ .real = 16 } },
        .{ .key = "iconSize", .value = .{ .real = window.icon_size } },
        .{ .key = "scrollPositionX", .value = .{ .real = 0 } },
        .{ .key = "scrollPositionY", .value = .{ .real = 0 } },
    });
    return .{
        .{ .name = ".", .code = "vSrn", .value = .{ .long = 1 } },
        .{ .name = ".", .code = "bwsp", .value = .{ .blob = bwsp } },
        .{ .name = ".", .code = "icvp", .value = .{ .blob = icvp } },
        .{ .name = ".", .code = "icvl", .value = .{ .type = "icnv" } }, // icon view
        try iconLocation(allocator, app, window.app_x, window.app_y),
        try iconLocation(allocator, "Applications", window.applications_x, window.applications_y),
    };
}

/// The .DS_Store of the window of a disk image holding `app`.
pub fn dmgLayout(allocator: std.mem.Allocator, app: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const records = try dmgRecords(arena.allocator(), app);
    return encode(allocator, &records);
}

const testing = std.testing;

// testdata/dmg.DS_Store was written by the ds_store Python package with the
// same records: the window's bwsp and icvp dictionaries, vSrn 1, icvl icnv,
// and the icons of "Hello Ziggurat.app" at (180, 190) and Applications at
// (480, 185).
test "the layout matches the one dmgbuild writes" {
    const layout = try dmgLayout(testing.allocator, "Hello Ziggurat.app");
    defer testing.allocator.free(layout);
    try testing.expectEqualSlices(u8, @embedFile("testdata/dmg.DS_Store"), layout);
}

test "binary property lists share equal scalars and encode text as plistlib does" {
    const bytes = try binaryPlist(testing.allocator, &.{
        .{ .key = "on", .value = .{ .boolean = true } },
        .{ .key = "also", .value = .{ .boolean = true } },
        .{ .key = "count", .value = .{ .integer = 300 } },
        .{ .key = "size", .value = .{ .real = 128 } },
        .{ .key = "name", .value = .{ .string = "h\u{e9}llo" } },
        .{ .key = "long", .value = .{ .string = "xxxxxxxxxxxxxxxxxxxx" } },
    });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "bplist00"));
    // A dictionary of six pairs: keys sorted, the two trues one object.
    try testing.expectEqual(@as(u8, 0xd6), bytes[8]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 7, 11 }, bytes[9..21]);
    try testing.expect(std.mem.indexOf(u8, bytes, &.{ 0x11, 0x01, 0x2c }) != null);
    try testing.expect(std.mem.indexOf(u8, bytes, &.{ 0x65, 0, 'h', 0, 0xe9, 0, 'l', 0, 'l', 0, 'o' }) != null);
    try testing.expect(std.mem.indexOf(u8, bytes, &.{ 0x5f, 0x10, 20 }) != null);
}
