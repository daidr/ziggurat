const std = @import("std");

/// The self-contained installer; it defines `window.__zigguratFind` once.
pub const installer = @embedFile("find.js");
pub const max_text_bytes = 4096;

pub const Options = struct {
    /// Find only text with the same capitalization.
    match_case: bool = false,
    /// Go to the previous match rather than the next one.
    backward: bool = false,
    /// Move on from the current match of the same text; otherwise the search
    /// starts over at the first match (the last when backward).
    find_next: bool = false,
};

/// Matches is how many there are; active is the current one from 1. Both are
/// 0 without matches.
pub const Result = struct { matches: u32, active: u32 };

/// Returns an owned script for the host's asynchronous JavaScript evaluation
/// in the page's top frame. It highlights every occurrence of `text`, scrolls
/// the active one into view and evaluates to a Result as JSON. Text split by
/// markup, such as "a<b>b</b>", is not found.
pub fn script(allocator: std.mem.Allocator, text: []const u8, options: Options) ![]u8 {
    if (text.len > max_text_bytes) return error.TextTooLong;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const w = &output.writer;
    w.writeAll(installer) catch return error.OutOfMemory;
    w.writeAll(";window.__zigguratFind.find(") catch return error.OutOfMemory;
    std.json.Stringify.value(text, .{}, w) catch return error.OutOfMemory;
    w.print(",{{matchCase:{},backward:{},findNext:{}}})", .{ options.match_case, options.backward, options.find_next }) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// Removes the highlights of the last find. Harmless before any find.
pub const stop_script = "window.__zigguratFind&&window.__zigguratFind.stop()";

/// Parses the evaluation's JSON. A page that replaced the finder or navigated
/// away mid-find yields InvalidResult rather than a guess.
pub fn parseResult(allocator: std.mem.Allocator, json: []const u8) !Result {
    const parsed = std.json.parseFromSlice(Result, allocator, json, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidResult;
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value.active > value.matches or (value.matches > 0 and value.active == 0)) return error.InvalidResult;
    return value;
}

test "find script quotes the text and carries the options" {
    const allocator = std.testing.allocator;
    const bytes = try script(allocator, "a\"b</script>\u{2028}", .{ .find_next = true });
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, installer));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "find(\"a\\\"b</script>\u{2028}\",{matchCase:false,backward:false,findNext:true})"));
    try std.testing.expectError(error.InvalidUtf8, script(allocator, "\xff", .{}));
    var long: [max_text_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.TextTooLong, script(allocator, &long, .{}));
}

test "find results are checked" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(Result{ .matches = 3, .active = 2 }, try parseResult(allocator, "{\"matches\":3,\"active\":2}"));
    try std.testing.expectEqual(Result{ .matches = 0, .active = 0 }, try parseResult(allocator, "{\"matches\":0,\"active\":0}"));
    try std.testing.expectError(error.InvalidResult, parseResult(allocator, "null"));
    try std.testing.expectError(error.InvalidResult, parseResult(allocator, "{\"matches\":1,\"active\":2}"));
    try std.testing.expectError(error.InvalidResult, parseResult(allocator, "{\"matches\":1,\"active\":0}"));
    try std.testing.expectError(error.InvalidResult, parseResult(allocator, "{\"matches\":-1,\"active\":0}"));
}
