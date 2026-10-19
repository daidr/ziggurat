const std = @import("std");
const Locale = @import("locale.zig").Locale;

/// Pseudolocalization for layout and coverage testing. `accented` keeps
/// text readable while replacing ASCII letters, brackets each message and
/// pads it by about 40 percent; `bidi` marks the message right-to-left and
/// embeds literal text in a right-to-left override. Arguments are never
/// transformed, so placeholders stay recognizable.
pub const Mode = enum { none, accented, bidi };

/// `XA` selects accented and `XB` bidi pseudolocalization, as in `en-XA`
/// and `ar-XB`; every other region selects none.
pub fn modeFor(locale: *const Locale) Mode {
    const region = locale.region() orelse return .none;
    if (std.mem.eql(u8, region, "XA")) return .accented;
    if (std.mem.eql(u8, region, "XB")) return .bidi;
    return .none;
}

const lower = [26][]const u8{ "á", "ƀ", "ç", "ð", "é", "ƒ", "ĝ", "ĥ", "î", "ĵ", "ķ", "ļ", "ɱ", "ñ", "ö", "þ", "ǫ", "ŕ", "š", "ţ", "û", "ṽ", "ŵ", "ẋ", "ý", "ž" };
const upper = [26][]const u8{ "Å", "Ɓ", "Ç", "Ð", "É", "Ƒ", "Ĝ", "Ĥ", "Î", "Ĵ", "Ķ", "Ļ", "Ṁ", "Ñ", "Ö", "Þ", "Ǫ", "Ŕ", "Š", "Ţ", "Û", "Ṽ", "Ŵ", "Ẋ", "Ý", "Ž" };

const rlm = "\u{200F}";
const rlo = "\u{202E}";
const pdf = "\u{202C}";

pub fn begin(writer: *std.Io.Writer, mode: Mode) error{WriteFailed}!void {
    switch (mode) {
        .none => {},
        .accented => try writer.writeAll("["),
        .bidi => try writer.writeAll(rlm),
    }
}

/// Transforms one run of literal message text.
pub fn writeText(writer: *std.Io.Writer, mode: Mode, text: []const u8) error{WriteFailed}!void {
    switch (mode) {
        .none => try writer.writeAll(text),
        .accented => for (text) |c| switch (c) {
            'a'...'z' => try writer.writeAll(lower[c - 'a']),
            'A'...'Z' => try writer.writeAll(upper[c - 'A']),
            else => try writer.writeByte(c),
        },
        .bidi => {
            if (text.len == 0) return;
            try writer.writeAll(rlo);
            try writer.writeAll(text);
            try writer.writeAll(pdf);
        },
    }
}

/// `literal_code_points` counts the literal text written since `begin` and
/// sets the accented padding.
pub fn end(writer: *std.Io.Writer, mode: Mode, literal_code_points: usize) error{WriteFailed}!void {
    switch (mode) {
        .none => {},
        .accented => {
            const padding = @max(1, (literal_code_points * 2 + 4) / 5);
            try writer.writeByte(' ');
            for (0..padding) |_| try writer.writeByte('~');
            try writer.writeAll("]");
        },
        .bidi => try writer.writeAll(rlm),
    }
}

/// Pseudolocalizes plain text that is not a message pattern, such as a
/// window title.
pub fn transform(writer: *std.Io.Writer, mode: Mode, text: []const u8) error{WriteFailed}!void {
    try begin(writer, mode);
    try writeText(writer, mode, text);
    try end(writer, mode, std.unicode.utf8CountCodepoints(text) catch text.len);
}

test "accented and bidi transforms" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try transform(&writer, .accented, "Save file");
    try std.testing.expectEqualStrings("[Šáṽé ƒîļé ~~~~]", writer.buffered());
    writer = .fixed(&buffer);
    try transform(&writer, .bidi, "Open");
    try std.testing.expectEqualStrings("\u{200F}\u{202E}Open\u{202C}\u{200F}", writer.buffered());
    writer = .fixed(&buffer);
    try transform(&writer, .none, "Open");
    try std.testing.expectEqualStrings("Open", writer.buffered());
    try std.testing.expectEqual(Mode.accented, modeFor(&(try Locale.parse("en-XA"))));
    try std.testing.expectEqual(Mode.bidi, modeFor(&(try Locale.parse("ar-XB"))));
    try std.testing.expectEqual(Mode.none, modeFor(&(try Locale.parse("en-US"))));
}
