//! Reads what font registration needs from TrueType and OpenType data: the
//! family name of each face (name ID 1, in English where the font has it)
//! and whether the font is fixed-pitch (`post.isFixedPitch`).
const std = @import("std");

pub const Faces = struct { count: usize, monospaced: bool };

fn be16(data: []const u8, at: usize) !u16 {
    if (at + 2 > data.len) return error.InvalidFont;
    return std.mem.readInt(u16, data[at..][0..2], .big);
}
fn be32(data: []const u8, at: usize) !u32 {
    if (at + 4 > data.len) return error.InvalidFont;
    return std.mem.readInt(u32, data[at..][0..4], .big);
}

/// The distinct family names of the faces of `data`, written to `names`,
/// at most `names.len`; whether the first face is fixed-pitch.
pub fn families(data: []const u8, names: [][127]u8, lens: []usize) !Faces {
    if (data.len < 12) return error.InvalidFont;
    var offsets: [64]u32 = undefined;
    var face_count: usize = 1;
    if (std.mem.eql(u8, data[0..4], "ttcf")) {
        const n = try be32(data, 8);
        if (n == 0) return error.InvalidFont;
        face_count = @min(n, offsets.len);
        for (0..face_count) |i| offsets[i] = try be32(data, 12 + 4 * i);
    } else offsets[0] = 0;
    var found: usize = 0;
    var monospaced = false;
    for (offsets[0..face_count], 0..) |offset, face| {
        const tag = try be32(data, offset);
        if (tag != 0x00010000 and tag != 0x4f54544f and tag != 0x74727565) return error.InvalidFont;
        if (face == 0) monospaced = fixedPitch(data, offset) catch false;
        var buffer: [127]u8 = undefined;
        const family_name = try familyName(data, offset, &buffer);
        if (family_name.len == 0) continue;
        var duplicate = false;
        for (0..found) |i| if (std.ascii.eqlIgnoreCase(names[i][0..lens[i]], family_name)) {
            duplicate = true;
        };
        if (duplicate or found == names.len) continue;
        @memcpy(names[found][0..family_name.len], family_name);
        lens[found] = family_name.len;
        found += 1;
    }
    return .{ .count = found, .monospaced = monospaced };
}

fn table(data: []const u8, offset: usize, tag: *const [4]u8) !?struct { start: usize, len: usize } {
    const tables = try be16(data, offset + 4);
    for (0..tables) |i| {
        const record = offset + 12 + 16 * i;
        if (record + 16 > data.len) return error.InvalidFont;
        if (!std.mem.eql(u8, data[record..][0..4], tag)) continue;
        const start = try be32(data, record + 8);
        const len = try be32(data, record + 12);
        if (@as(u64, start) + len > data.len) return error.InvalidFont;
        return .{ .start = start, .len = len };
    }
    return null;
}

fn fixedPitch(data: []const u8, offset: usize) !bool {
    const post = (try table(data, offset, "post")) orelse return false;
    if (post.len < 16) return false;
    return try be32(data, post.start + 12) != 0;
}

/// Name ID 1: Windows Unicode English (US) first, then any Windows Unicode,
/// then Macintosh Roman English. Empty when the font has none.
fn familyName(data: []const u8, offset: usize, out: *[127]u8) ![]const u8 {
    const names = (try table(data, offset, "name")) orelse return "";
    const base = names.start;
    const records = try be16(data, base + 2);
    const strings = base + try be16(data, base + 4);
    var best: ?struct { rank: u8, start: usize, len: usize, utf16: bool } = null;
    for (0..records) |i| {
        const r = base + 6 + 12 * i;
        const platform = try be16(data, r);
        const encoding = try be16(data, r + 2);
        const language = try be16(data, r + 4);
        if (try be16(data, r + 6) != 1) continue;
        const len = try be16(data, r + 8);
        const start = strings + try be16(data, r + 10);
        if (start + len > data.len) continue;
        const rank: u8 = if (platform == 3 and (encoding == 1 or encoding == 10) and language == 0x409) 0 else if (platform == 3 and (encoding == 1 or encoding == 10)) 1 else if (platform == 0) 2 else if (platform == 1 and encoding == 0 and language == 0) 3 else continue;
        if (best == null or rank < best.?.rank) best = .{ .rank = rank, .start = start, .len = len, .utf16 = platform != 1 };
    }
    const chosen = best orelse return "";
    const raw = data[chosen.start..][0..chosen.len];
    var written: usize = 0;
    if (chosen.utf16) {
        var i: usize = 0;
        while (i + 1 < raw.len) : (i += 2) {
            var unit: u21 = std.mem.readInt(u16, raw[i..][0..2], .big);
            if (unit >= 0xd800 and unit < 0xdc00 and i + 3 < raw.len) {
                const low = std.mem.readInt(u16, raw[i + 2 ..][0..2], .big);
                if (low >= 0xdc00 and low < 0xe000) {
                    unit = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00);
                    i += 2;
                }
            }
            if (unit >= 0xd800 and unit < 0xe000) unit = 0xfffd;
            if (unit == 0) continue;
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(unit, &encoded) catch continue;
            if (written + n > out.len) break;
            @memcpy(out[written..][0..n], encoded[0..n]);
            written += n;
        }
    } else for (raw) |byte| {
        // Macintosh Roman names of English fonts are ASCII in practice.
        if (byte == 0 or byte >= 0x80 or written == out.len) continue;
        out[written] = byte;
        written += 1;
    }
    return std.mem.trim(u8, out[0..written], " ");
}

/// A minimal font of one face with `family` as name ID 1, for tests.
pub fn testFont(comptime family: []const u8, comptime fixed: bool) [12 + 32 + 6 + 12 + family.len * 2 + 32]u8 {
    var font: [12 + 32 + 6 + 12 + family.len * 2 + 32]u8 = @splat(0);
    std.mem.writeInt(u32, font[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, font[4..6], 2, .big);
    const name_start = 12 + 32;
    const name_len = 6 + 12 + family.len * 2;
    const post_start = name_start + name_len;
    @memcpy(font[12..16], "name");
    std.mem.writeInt(u32, font[20..24], name_start, .big);
    std.mem.writeInt(u32, font[24..28], name_len, .big);
    @memcpy(font[28..32], "post");
    std.mem.writeInt(u32, font[36..40], post_start, .big);
    std.mem.writeInt(u32, font[40..44], 32, .big);
    std.mem.writeInt(u16, font[name_start + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u16, font[name_start + 4 ..][0..2], 18, .big);
    const record = name_start + 6;
    std.mem.writeInt(u16, font[record..][0..2], 3, .big);
    std.mem.writeInt(u16, font[record + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u16, font[record + 4 ..][0..2], 0x409, .big);
    std.mem.writeInt(u16, font[record + 6 ..][0..2], 1, .big);
    std.mem.writeInt(u16, font[record + 8 ..][0..2], family.len * 2, .big);
    for (family, 0..) |c, i| font[record + 12 + 2 * i + 1] = c;
    if (fixed) std.mem.writeInt(u32, font[post_start + 12 ..][0..4], 1, .big);
    return font;
}

test "family names and fixed pitch come from the name and post tables" {
    const font = testFont("Test Mono", true);
    var names: [4][127]u8 = undefined;
    var lens: [4]usize = undefined;
    const faces = try families(&font, &names, &lens);
    try std.testing.expectEqual(@as(usize, 1), faces.count);
    try std.testing.expect(faces.monospaced);
    try std.testing.expectEqualStrings("Test Mono", names[0][0..lens[0]]);
    try std.testing.expectError(error.InvalidFont, families("not a font at all", &names, &lens));
}
