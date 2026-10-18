const std = @import("std");
const http = @import("ziggurat_http_response");
const file_response = @import("file_response.zig");
const FileRequest = file_response.FileRequest;
const PreparedFileResponse = file_response.PreparedFileResponse;

test "file request owns metadata and numeric range without retaining callback bytes" {
    var tag = "\"fixture-v1\"".*;
    var mime = "text/plain".*;
    var value = "bytes=17-21".*;
    var headers = [_]http.Header{ .{ .name = "Range", .value = &value }, .{ .name = "If-Range", .value = "\"fixture-v1\"" } };
    const request = try FileRequest.capture(.get, &headers, .{ .etag = &tag, .mime = &mime });
    @memset(&tag, 'x');
    @memset(&mime, 'x');
    @memset(&value, 'x');
    headers[0] = .{ .name = "Changed", .value = "changed" };
    try std.testing.expectEqualStrings("\"fixture-v1\"", try request.etag());
    try std.testing.expectEqualStrings("text/plain", try request.mime());
    try std.testing.expectEqualDeep(http.byte_range.Selection{ .partial = .{ .offset = 17, .length = 5, .total = 36 } }, try request.select(36));
}

test "file request rejects forbidden methods and oversized descriptors before bytes" {
    const invalid: [*]const u8 = @ptrFromInt(1);
    const invalid_headers: [*]const http.Header = @ptrFromInt(@alignOf(http.Header));
    try std.testing.expectError(error.MethodDenied, FileRequest.capture(.post, invalid_headers[0..1], .{ .etag = invalid[0..1] }));
    try std.testing.expectError(error.RequestHeadersExceeded, FileRequest.capture(.get, invalid_headers[0..65], .{ .etag = invalid[0..1] }));
    try std.testing.expectError(error.InvalidFileEntityTag, FileRequest.capture(.get, &.{}, .{ .etag = invalid[0..257] }));
    try std.testing.expectError(error.InvalidMime, FileRequest.capture(.get, &.{}, .{ .etag = "\"v\"", .mime = invalid[0..128] }));
}

test "file request independently revalidates public lengths method and parsed spec" {
    const request = try FileRequest.capture(.get, &.{}, .{ .etag = "\"v\"" });
    var changed = request;
    changed.etag_length = 257;
    try std.testing.expectError(error.InvalidFileEntityTag, changed.select(36));
    changed = request;
    changed.mime_length = 128;
    try std.testing.expectError(error.InvalidMime, changed.select(36));
    changed = request;
    changed.method = .put;
    try std.testing.expectError(error.MethodDenied, changed.select(36));
    changed = request;
    changed.method = .head;
    changed.condition_matches = false;
    changed.parsed = .{ .single = .{ .closed = .{ .first = 10, .last = 9 } } };
    try std.testing.expectError(error.InvalidSpec, changed.select(36));
    changed = request;
    changed.etag_storage[0] = 'W';
    try std.testing.expectError(error.InvalidFileEntityTag, changed.select(36));
}

test "file request requires a strong response-safe current tag and MIME" {
    for ([_][]const u8{ "", "v", "W/\"v\"", " \"v\"", "\"v\" ", "\"bad\"tag\"", "\"\x80\"", "\"bad\n\"" }) |tag| {
        try std.testing.expectError(error.InvalidFileEntityTag, FileRequest.capture(.get, &.{}, .{ .etag = tag }));
    }
    for ([_][]const u8{ "", "text/plain\r\nX: bad", "\x80" }) |mime| {
        try std.testing.expectError(error.InvalidMime, FileRequest.capture(.get, &.{}, .{ .etag = "\"v\"", .mime = mime }));
    }
    const tag = "\"" ++ "v" ** 254 ++ "\"";
    const request = try FileRequest.capture(.get, &.{}, .{ .etag = tag, .mime = "a" ** 127 });
    try std.testing.expectEqual(@as(usize, 256), (try request.etag()).len);
    try std.testing.expectEqual(@as(usize, 127), (try request.mime()).len);
}

test "file request GET applies complete grammar and observed duplicate policy" {
    for ([_][]const u8{ "bytes=18446744073709551616-0,bad", "bytes=0-1,broken", "bytes=5-3", "x" ** 257 }) |bad| {
        try std.testing.expectError(if (bad.len > 256) error.TooLong else error.InvalidRange, FileRequest.capture(.get, &.{.{ .name = "Range", .value = bad }}, .{ .etag = "\"v\"" }));
    }
    try std.testing.expectError(error.DuplicateRangeHeader, FileRequest.capture(.get, &.{ .{ .name = "Range", .value = "bytes=0-1" }, .{ .name = "rAnGe", .value = "bytes=0-1" } }, .{ .etag = "\"v\"" }));
    try std.testing.expectError(error.DuplicateIfRangeHeader, FileRequest.capture(.get, &.{ .{ .name = "Range", .value = "bytes=0-1" }, .{ .name = "If-Range", .value = "\"v\"" }, .{ .name = "if-range", .value = "\"v\"" } }, .{ .etag = "\"v\"" }));
    for ([_][]const u8{ "bytes=0-1,4-5", "items=0-1", "bytes=18446744073709551616-" }) |full| {
        const request = try FileRequest.capture(.get, &.{.{ .name = "Range", .value = full }}, .{ .etag = "\"v\"" });
        try std.testing.expectEqualDeep(http.byte_range.Selection.full, try request.select(36));
    }
}

test "file request HEAD ignores range semantics and if-range alone remains ignored" {
    const headers = [_]http.Header{ .{ .name = "Range", .value = "malformed" }, .{ .name = "range", .value = "also malformed" }, .{ .name = "If-Range", .value = "bad" }, .{ .name = "if-range", .value = "bad" } };
    const head = try FileRequest.capture(.head, &headers, .{ .etag = "\"v\"" });
    try std.testing.expectEqualDeep(http.byte_range.Selection.full, try head.select(36));
    const alone = try FileRequest.capture(.get, headers[2..], .{ .etag = "\"v\"" });
    try std.testing.expectEqualDeep(http.byte_range.Selection.full, try alone.select(36));
    try std.testing.expectError(error.InvalidRequestHeader, FileRequest.capture(.head, &.{.{ .name = "Range", .value = "bad\tvalue" }}, .{ .etag = "\"v\"" }));
}

test "file request validator outcomes and empty selection remain explicit" {
    for ([_][]const u8{ "\"different\"", "W/\"v\"", "Sun, 06 Nov 1994 08:49:37 GMT", "" }) |condition| {
        const request = try FileRequest.capture(.get, &.{ .{ .name = "Range", .value = "bytes=0-1" }, .{ .name = "If-Range", .value = condition } }, .{ .etag = "\"v\"" });
        try std.testing.expectEqualDeep(http.byte_range.Selection.full, try request.select(36));
    }
    const request = try FileRequest.capture(.get, &.{.{ .name = "Range", .value = "bytes=36-" }}, .{ .etag = "\"v\"" });
    try std.testing.expectEqualDeep(http.byte_range.Selection{ .unsatisfiable = 36 }, try request.select(36));
    try std.testing.expectEqualDeep(http.byte_range.Selection.full, try request.select(0));
}

test "metadata-only 416 owns no source and withdraws once without native work" {
    const request = try FileRequest.capture(.get, &.{.{ .name = "Range", .value = "bytes=36-" }}, .{ .etag = "\"v\"", .mime = "text/plain" });
    var response: PreparedFileResponse = .{ .request = request, .selection = .{ .unsatisfiable = 36 }, .total = 36 };
    var metadata: file_response.Metadata = undefined;
    try metadata.init(&response);
    try std.testing.expectEqual(@as(u16, 416), metadata.head.status);
    try std.testing.expectEqual(@as(u64, 0), metadata.head.length);
    try std.testing.expectEqualStrings("text/plain", metadata.head.mime);
    try std.testing.expectEqual(@as(usize, 5), metadata.head.headers.len);
    try std.testing.expectEqualStrings("Content-Range", metadata.head.headers[4].name);
    try std.testing.expectEqualStrings("bytes */36", metadata.head.headers[4].value);
    try metadata.head.validate(1024);
    response.total = 35;
    try std.testing.expectError(error.InvalidSelection, metadata.init(&response));
    response.total = 36;
    response.request.method = .head;
    try std.testing.expectError(error.InvalidSelection, metadata.init(&response));
    response.deinit();
    response.deinit();
    try std.testing.expect(!response.ready and response.source == null);
    try std.testing.expectError(error.ResponseMoved, metadata.init(&response));
}

test "unavailable file helper is cold before input thread or file access" {
    const os = @import("builtin").os.tag;
    if ((os == .linux or os == .windows) and @import("ziggurat_https_resources_options").enabled) return;
    var request = try FileRequest.capture(.get, &.{}, .{ .etag = "\"v\"" });
    request.etag_length = 65535;
    const file: std.fs.File = .{ .handle = if (@import("builtin").os.tag == .windows) @ptrFromInt(1) else -1 };
    try std.testing.expectError(error.UnsupportedCapability, PreparedFileResponse.prepare(std.Thread.getCurrentId(), file, 0, request));
}
