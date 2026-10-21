//! The accessors `ziggurat generate` writes compile and say their
//! messages: tests/i18n_fixture through tools/i18n_catalog.zig.
const std = @import("std");
const i18n = @import("ziggurat_i18n");
const catalog = @import("fixture_catalog");

test "generated accessors format in each language and fall back to the source" {
    try std.testing.expectEqualStrings("en", catalog.source);
    try std.testing.expectEqual(@as(usize, 2), catalog.languages.len);
    var messages_catalog = try catalog.catalog(std.testing.allocator);
    defer messages_catalog.deinit();
    const german_localizer = i18n.Localizer.init(&messages_catalog, try i18n.Locale.parse("de-AT"), .{ .missing = .fail });
    const english_localizer = i18n.Localizer.init(&messages_catalog, try i18n.Locale.parse("en"), .{ .missing = .fail });
    const german: catalog.Messages = .in(&german_localizer);
    const english: catalog.Messages = .in(&english_localizer);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try german.greeting(&writer, "Ana");
    try german.files(&writer, 1);
    try writer.writeByte('|');
    try german.files(&writer, 3);
    try writer.writeByte('|');
    try english.share(&writer, 0.25);
    try writer.writeByte('|');
    // Missing in German, said in English.
    try german.@"error"(&writer, "Save");
    try std.testing.expectEqualStrings("Hallo, Ana!1 Datei|3 Dateien|25% done|Save failed", writer.buffered());
    writer = .fixed(&buffer);
    try english.saved(&writer, .{ .unix_seconds = 0 });
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Saved on "));
}
