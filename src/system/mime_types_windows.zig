//! The extensions of the media types an open dialog filters by on Windows,
//! whose file pickers take extensions only: those HKEY_CLASSES_ROOT gives
//! the type, by each extension's Content Type (and, for all of a kind such
//! as "image/*", its PerceivedType), and the extension
//! MIME\Database\Content Type names for it. Read as a dialog opens.
const std = @import("std");
const c = @import("ziggurat_c_win32");
const picker = @import("picker.zig");

const hkcr: c.HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000000)))))));

/// Calls `sink.add` with each extension, its dot included, of every one of
/// `types`, in registry order and possibly more than once.
pub fn extensions(types: []const []const u8, sink: anytype) void {
    var name: [256]u16 = undefined;
    var index: c.DWORD = 0;
    while (true) : (index += 1) {
        var length: c.DWORD = name.len;
        const status = c.RegEnumKeyExW(hkcr, index, &name, &length, null, null, null, null);
        if (status == c.ERROR_MORE_DATA) continue; // too long for an extension
        if (status != c.ERROR_SUCCESS) break;
        if (length < 2 or name[0] != '.') continue;
        name[length] = 0;
        var key: c.HKEY = null;
        if (c.RegOpenKeyExW(hkcr, @ptrCast(&name), 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) continue;
        defer _ = c.RegCloseKey(key);
        var content: [128]u8 = undefined;
        var perceived: [32]u8 = undefined;
        const entry: picker.MimeEntry = .{
            .content_type = value(key, std.unicode.utf8ToUtf16LeStringLiteral("Content Type"), &content),
            .perceived = value(key, std.unicode.utf8ToUtf16LeStringLiteral("PerceivedType"), &perceived),
        };
        if (entry.content_type.len == 0 and entry.perceived.len == 0) continue;
        for (types) |mime| if (picker.mimeMatches(mime, entry)) {
            sink.add(name[0..length]);
            break;
        };
    }
    // The extension the MIME database names for a type, which an
    // extension of its own may not say it is.
    var path: [200]u16 = undefined;
    for (types) |mime| {
        if (std.mem.endsWith(u8, mime, "/*")) continue;
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("MIME\\Database\\Content Type\\");
        if (prefix.len + mime.len + 1 > path.len) continue;
        @memcpy(path[0..prefix.len], prefix);
        const written = std.unicode.utf8ToUtf16Le(path[prefix.len..], mime) catch continue;
        path[prefix.len + written] = 0;
        var key: c.HKEY = null;
        if (c.RegOpenKeyExW(hkcr, @ptrCast(&path), 0, c.KEY_QUERY_VALUE, &key) != c.ERROR_SUCCESS) continue;
        defer _ = c.RegCloseKey(key);
        var wide: [64]u16 = undefined;
        var size: c.DWORD = @sizeOf(@TypeOf(wide));
        var kind: c.DWORD = 0;
        if (c.RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("Extension"), null, &kind, @ptrCast(&wide), &size) != c.ERROR_SUCCESS or kind != c.REG_SZ) continue;
        var units: usize = size / 2;
        while (units > 0 and wide[units - 1] == 0) units -= 1;
        if (units >= 2 and wide[0] == '.') sink.add(wide[0..units]);
    }
}

/// A string value of `key`, lowered to ASCII lower case, or "" when it has
/// none or it is not ASCII.
fn value(key: c.HKEY, name: [*:0]const u16, out: []u8) []const u8 {
    var wide: [128]u16 = undefined;
    var size: c.DWORD = @sizeOf(@TypeOf(wide));
    var kind: c.DWORD = 0;
    if (c.RegQueryValueExW(key, name, null, &kind, @ptrCast(&wide), &size) != c.ERROR_SUCCESS or kind != c.REG_SZ) return "";
    var units: usize = size / 2;
    while (units > 0 and wide[units - 1] == 0) units -= 1;
    if (units > out.len) return "";
    for (wide[0..units], 0..) |unit, index| {
        if (unit >= 0x80) return "";
        out[index] = std.ascii.toLower(@intCast(unit));
    }
    return out[0..units];
}
