//! Terminal color themes: the default foreground and background, the
//! cursor's and the selection's colors, the colors of search matches and
//! the 16 colors of programs. Programs may change them (OSC 4, 10, 11, 12)
//! until they reset. The themes Ghostty ships are built in, by name, and
//! theme files in Ghostty's format are read too.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const data = @import("theme_data.zig");

pub const Theme = struct {
    foreground: u24,
    background: u24,
    /// The cursor's color: the foreground when null. `cursor_text` colors
    /// the text under a block cursor: the background when null.
    cursor: ?u24 = null,
    cursor_text: ?u24 = null,
    /// The selection's background: the foreground at a third over the
    /// background when null. `selection_text` colors selected text: its
    /// own colors when null.
    selection: ?u24 = null,
    selection_text: ?u24 = null,
    /// Search matches and their text, then the selected match and its
    /// text: a light amber and a light orange under black text when null.
    search: ?u24 = null,
    search_text: ?u24 = null,
    search_selected: ?u24 = null,
    search_selected_text: ?u24 = null,
    /// Black, red, green, yellow, blue, magenta, cyan and white, then their
    /// bright kinds.
    palette: [16]u24,

    /// Whether the background is dark.
    pub fn isDark(self: Theme) bool {
        const b = self.background;
        const r: u32 = @as(u8, @truncate(b >> 16));
        const g: u32 = @as(u8, @truncate(b >> 8));
        const bl: u32 = @as(u8, @truncate(b));
        return 299 * r + 587 * g + 114 * bl < 128 * 1000;
    }

    /// The 256 colors: the theme's 16, xterm's 6×6×6 cube and its 24 grays.
    pub fn palette256(self: Theme) [256]u24 {
        var out: [256]u24 = undefined;
        @memcpy(out[0..16], &self.palette);
        const levels = [6]u24{ 0, 95, 135, 175, 215, 255 };
        for (0..216) |i| out[16 + i] = levels[i / 36] << 16 | levels[i / 6 % 6] << 8 | levels[i % 6];
        for (0..24) |i| {
            const v: u24 = @intCast(8 + 10 * i);
            out[232 + i] = v << 16 | v << 8 | v;
        }
        return out;
    }

    pub fn cursorColor(self: Theme) u24 {
        return self.cursor orelse self.foreground;
    }
    pub fn selectionColor(self: Theme) u24 {
        return self.selection orelse mix(self.background, self.foreground, 1.0 / 3.0);
    }
    pub fn searchColors(self: Theme) struct { match: u24, text: u24, selected: u24, selected_text: u24 } {
        return .{ .match = self.search orelse 0xffe082, .text = self.search_text orelse 0, .selected = self.search_selected orelse 0xf2a57e, .selected_text = self.search_selected_text orelse 0 };
    }
};

/// The colors of terminals in dark windows: a dark background and light
/// text, with Visual Studio Code's palette.
pub const dark: Theme = .{ .foreground = 0xf0f3f6, .background = 0x181c22, .palette = .{
    0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
    0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff,
} };

/// The colors of terminals in light windows: a light background and dark
/// text, with Visual Studio Code's palette.
pub const light: Theme = .{ .foreground = 0x182430, .background = 0xffffff, .palette = .{
    0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555,
    0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5,
} };

/// The theme of a window's appearance.
pub fn default(is_dark: bool) Theme {
    return if (is_dark) dark else light;
}

/// Mix `a` toward `b` by `t`, from 0 (a) to 1 (b).
pub fn mix(a: u24, b: u24, t: f32) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: f32 = @floatFromInt(@as(u8, @truncate(a >> shift)));
        const y: f32 = @floatFromInt(@as(u8, @truncate(b >> shift)));
        out |= @as(u24, @intFromFloat(@round(x + (y - x) * t))) << shift;
    }
    return out;
}

// ---- Ghostty's themes --------------------------------------------------

/// A theme Ghostty ships, by name: exact, else ignoring case.
pub fn builtinTheme(name: []const u8) ?Theme {
    for (data.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return fromEntry(entry);
    for (data.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return fromEntry(entry);
    return null;
}

/// The themes Ghostty ships, by name; `names` sorts them with the user's.
pub fn builtinNames() []const data.Entry {
    return &data.entries;
}

fn fromEntry(entry: data.Entry) Theme {
    const c = entry.colors;
    return .{ .palette = c[0..16].*, .background = c[16], .foreground = c[17], .cursor = c[18], .cursor_text = c[19], .selection = c[20], .selection_text = c[21] };
}

pub const LookupError = error{ NoSuchTheme, InvalidThemeName } || ParseError || std.Io.File.OpenError || std.Io.File.Reader.Error || std.mem.Allocator.Error || error{ FileTooBig, StreamTooLong };

/// A theme by name, as Ghostty's `theme` option takes it: a theme file of
/// the user's in Ghostty's themes directory first (`$XDG_CONFIG_HOME/
/// ghostty/themes`, `~/.config/ghostty/themes` by default, and
/// `%LOCALAPPDATA%\ghostty\themes` on Windows without XDG_CONFIG_HOME),
/// else one Ghostty ships, of any case; an absolute path names a theme
/// file. `env` is the environment to read those variables from.
pub fn lookup(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) LookupError!Theme {
    if (std.fs.path.isAbsolute(name)) return readFile(allocator, name);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidThemeName;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (userThemesDir(env, &buffer)) |dir| {
        var joined: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&joined, "{s}{c}{s}", .{ dir, std.fs.path.sep, name })) |path| {
            if (readFile(allocator, path)) |found| return found else |err| if (err != error.FileNotFound) return err;
        } else |_| {}
    }
    return builtinTheme(name) orelse error.NoSuchTheme;
}

/// Ghostty's themes directory of the user, as Ghostty finds it.
pub fn userThemesDir(env: *const std.process.Environ.Map, buffer: []u8) ?[]const u8 {
    const sep = std.fs.path.sep_str;
    if (env.get("XDG_CONFIG_HOME")) |dir| if (dir.len > 0) return std.fmt.bufPrint(buffer, "{s}" ++ sep ++ "ghostty" ++ sep ++ "themes", .{dir}) catch null;
    if (builtin.os.tag == .windows) if (env.get("LOCALAPPDATA")) |dir| if (dir.len > 0) return std.fmt.bufPrint(buffer, "{s}" ++ sep ++ "ghostty" ++ sep ++ "themes", .{dir}) catch null;
    const home = env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}" ++ sep ++ ".config" ++ sep ++ "ghostty" ++ sep ++ "themes", .{home}) catch null;
}

/// The names `lookup` takes, sorted ignoring case and without repeats:
/// the user's theme files and Ghostty's themes. Free with `freeNames`.
pub fn names(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (data.entries) |entry| {
        const copy = try allocator.dupe(u8, entry.name);
        list.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };
    }
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (userThemesDir(env, &buffer)) |path| {
        if (std.Io.Dir.openDirAbsolute(zio.io(), path, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(zio.io());
            var it = dir.iterate();
            while (it.next(zio.io()) catch null) |entry| {
                if (entry.kind == .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
                const copy = try allocator.dupe(u8, entry.name);
                list.append(allocator, copy) catch |err| {
                    allocator.free(copy);
                    return err;
                };
            }
        } else |_| {}
    }
    std.mem.sort([]const u8, list.items, {}, lessName);
    // Drop repeats.
    var kept: usize = 0;
    for (list.items) |item| {
        if (kept > 0 and std.mem.eql(u8, list.items[kept - 1], item)) {
            allocator.free(item);
            continue;
        }
        list.items[kept] = item;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
    return list.toOwnedSlice(allocator);
}

pub fn freeNames(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a, b) == .lt;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) LookupError!Theme {
    const file = try std.Io.Dir.openFileAbsolute(zio.io(), path, .{});
    defer file.close(zio.io());
    const bytes = try zio.readToEndAlloc(file, allocator, 1 << 20);
    defer allocator.free(bytes);
    return parse(bytes);
}

pub const ParseError = error{ ThemeLineSetsNothing, InvalidPaletteEntry, InvalidThemeColor };

/// Read a theme in Ghostty's format, the lines of its configuration that
/// set colors:
///
/// ```
/// palette = 0=#45475a
/// background = #1e1e2e
/// foreground = #cdd6f4
/// cursor-color = #f5e0dc
/// cursor-text = #1e1e2e
/// selection-background = #f5e0dc
/// selection-foreground = #1e1e2e
/// ```
///
/// Colors are hex (#rgb, #rrggbb, rrggbb…). Other options, palette entries
/// past the 16th and colors set to cell-foreground or cell-background
/// (which the terminal then picks itself) are ignored. Colors a theme
/// leaves out are those of `dark`, or `light` when its background is
/// light.
pub fn parse(bytes: []const u8) ParseError!Theme {
    var out: Theme = .{ .foreground = 0, .background = 0, .palette = @splat(0) };
    var set_fg = false;
    var set_bg = false;
    var set_palette: [16]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.ThemeLineSetsNothing;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        const Slot = union(enum) { required: *u24, optional: *?u24, palette: usize };
        const slot: Slot = if (std.mem.eql(u8, key, "background"))
            .{ .required = &out.background }
        else if (std.mem.eql(u8, key, "foreground"))
            .{ .required = &out.foreground }
        else if (std.mem.eql(u8, key, "cursor-color"))
            .{ .optional = &out.cursor }
        else if (std.mem.eql(u8, key, "cursor-text"))
            .{ .optional = &out.cursor_text }
        else if (std.mem.eql(u8, key, "selection-background"))
            .{ .optional = &out.selection }
        else if (std.mem.eql(u8, key, "selection-foreground"))
            .{ .optional = &out.selection_text }
        else if (std.mem.eql(u8, key, "search-background"))
            .{ .optional = &out.search }
        else if (std.mem.eql(u8, key, "search-foreground"))
            .{ .optional = &out.search_text }
        else if (std.mem.eql(u8, key, "search-selected-background"))
            .{ .optional = &out.search_selected }
        else if (std.mem.eql(u8, key, "search-selected-foreground"))
            .{ .optional = &out.search_selected_text }
        else if (std.mem.eql(u8, key, "palette")) blk: {
            const at = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidPaletteEntry;
            const index = parseIndex(std.mem.trim(u8, value[0..at], " \t")) orelse return error.InvalidPaletteEntry;
            value = std.mem.trim(u8, value[at + 1 ..], " \t");
            if (index >= 16) continue;
            break :blk .{ .palette = index };
        } else continue;
        const unset = value.len == 0 or std.mem.eql(u8, value, "cell-foreground") or std.mem.eql(u8, value, "cell-background");
        const color: ?u24 = if (unset) null else (parseHex(value) orelse return error.InvalidThemeColor);
        switch (slot) {
            .required => |ptr| {
                ptr.* = color orelse 0;
                if (ptr == &out.background) set_bg = color != null else set_fg = color != null;
            },
            .optional => |ptr| ptr.* = color,
            .palette => |index| {
                out.palette[index] = color orelse 0;
                set_palette[index] = color != null;
            },
        }
    }
    const base = if (set_bg and !out.isDark()) light else dark;
    if (!set_bg) out.background = base.background;
    if (!set_fg) out.foreground = base.foreground;
    for (&out.palette, set_palette, base.palette) |*color, set, fallback| {
        if (!set) color.* = fallback;
    }
    return out;
}

/// A palette index in decimal, or hex or octal with a 0x or 0o prefix.
fn parseIndex(text: []const u8) ?u8 {
    return std.fmt.parseInt(u8, text, 0) catch null;
}

/// A color as Ghostty reads hex: #rgb, #rrggbb, #rrrgggbbb or
/// #rrrrggggbbbb, or the first two without #.
pub fn parseHex(text: []const u8) ?u24 {
    const hex = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (hex.len == text.len and hex.len != 3 and hex.len != 6) return null;
    if (hex.len == 0 or hex.len % 3 != 0 or hex.len > 12) return null;
    const w = hex.len / 3;
    const max: u32 = (@as(u32, 1) << @intCast(4 * w)) - 1;
    var out: u24 = 0;
    for (0..3) |i| {
        const v = std.fmt.parseInt(u16, hex[i * w ..][0..w], 16) catch return null;
        out = out << 8 | @as(u24, @intCast(@as(u32, v) * 255 / max));
    }
    return out;
}

test "Ghostty's themes are built in by name, of any case" {
    const mocha = builtinTheme("Catppuccin Mocha").?;
    try std.testing.expectEqual(@as(u24, 0x1e1e2e), mocha.background);
    try std.testing.expect(mocha.isDark());
    const latte = builtinTheme("catppuccin latte").?;
    try std.testing.expect(!latte.isDark());
    try std.testing.expect(builtinTheme("No Such Theme") == null);
    try std.testing.expect(builtinNames().len > 400);
}

test "theme files parse as Ghostty reads them" {
    const t = try parse(
        \\# comment
        \\palette = 0=#45475a
        \\palette = 1 = f38ba8
        \\palette = 20=#ffffff
        \\background = "#1e1e2e"
        \\foreground = #cdd6f4
        \\cursor-color = #f5e0dc
        \\selection-background = cell-foreground
        \\search-background = #fff
        \\font-family = Something
    );
    try std.testing.expectEqual(@as(u24, 0x45475a), t.palette[0]);
    try std.testing.expectEqual(@as(u24, 0xf38ba8), t.palette[1]);
    try std.testing.expectEqual(dark.palette[2], t.palette[2]);
    try std.testing.expectEqual(@as(u24, 0x1e1e2e), t.background);
    try std.testing.expectEqual(@as(?u24, 0xf5e0dc), t.cursor);
    try std.testing.expectEqual(@as(?u24, null), t.selection);
    try std.testing.expectEqual(@as(?u24, 0xffffff), t.search);
    // A light background takes the light theme's other colors.
    const l = try parse("background = #ffffff");
    try std.testing.expectEqual(light.foreground, l.foreground);
    try std.testing.expectEqual(light.palette[3], l.palette[3]);
    try std.testing.expectError(error.ThemeLineSetsNothing, parse("background"));
    try std.testing.expectError(error.InvalidThemeColor, parse("background = blue"));
    try std.testing.expectError(error.InvalidPaletteEntry, parse("palette = x=#000"));
    try std.testing.expectEqual(@as(?u24, 0x112233), parseHex("#111222333"));
    try std.testing.expectEqual(@as(?u24, 0xff0000), parseHex("f00"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("ff00"));
}

test "user theme files come before the shipped ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(zio.io(), "ghostty/themes");
    try tmp.dir.writeFile(zio.io(), .{ .sub_path = "ghostty/themes/Dracula", .data = "background = #010203\n" });
    try tmp.dir.writeFile(zio.io(), .{ .sub_path = "ghostty/themes/Mine", .data = "background = #ffffff\n" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try zio.realpath(tmp.dir, ".", &path_buffer);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);
    try std.testing.expectEqual(@as(u24, 0x010203), (try lookup(std.testing.allocator, &env, "Dracula")).background);
    try std.testing.expect(!(try lookup(std.testing.allocator, &env, "Mine")).isDark());
    try std.testing.expectEqual(@as(u24, 0x1e1e2e), (try lookup(std.testing.allocator, &env, "Catppuccin Mocha")).background);
    try std.testing.expectError(error.NoSuchTheme, lookup(std.testing.allocator, &env, "Nope"));
    try std.testing.expectError(error.InvalidThemeName, lookup(std.testing.allocator, &env, "../x"));
    const list = try names(std.testing.allocator, &env);
    defer freeNames(std.testing.allocator, list);
    try std.testing.expectEqual(builtinNames().len + 1, list.len);
    var found = false;
    for (list) |item| found = found or std.mem.eql(u8, item, "Mine");
    try std.testing.expect(found);
}

test "the palette's 256 colors" {
    const p = dark.palette256();
    try std.testing.expectEqual(dark.palette[9], p[9]);
    try std.testing.expectEqual(@as(u24, 0x5f87af), p[67]);
    try std.testing.expectEqual(@as(u24, 0xeeeeee), p[255]);
    try std.testing.expectEqual(@as(u24, 0x808080), mix(0, 0xffffff, 0.5));
}
