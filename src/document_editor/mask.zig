//! Masked text for password fields. Every scalar is replaced in place with
//! a placeholder of the same UTF-8 length that shapes as one grapheme of one
//! advance, so byte offsets, caret stops and selection geometry stay those
//! of the Document while no glyph of the password is shaped, drawn or handed
//! to the native text client. The Adapter draws a bullet in each placeholder.
const std = @import("std");

/// One base letter, its 2-byte look-alike, and each followed by the
/// combining grapheme joiner, which is invisible, has no advance, and stays
/// in the grapheme of the letter before it.
const placeholders = [4][]const u8{ "o", "\xce\xbf", "o\xcd\x8f", "\xce\xbf\xcd\x8f" };

pub fn apply(bytes: []u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
        const n = @min(length, bytes.len - at);
        @memcpy(bytes[at..][0..n], placeholders[n - 1]);
        at += n;
    }
}

test "masking keeps every scalar's length and hides its bytes" {
    var text = "a\xc3\xa9\xe4\xb8\xad\xf0\x9f\x94\x91".*;
    apply(&text);
    try std.testing.expectEqualStrings("o\xce\xbfo\xcd\x8f\xce\xbf\xcd\x8f", &text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(&text));
}
