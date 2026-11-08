//! Video files and streams played with the system's own media framework,
//! for `ziggurat_view_video.Player.show` to show: AVFoundation on macOS,
//! GStreamer on Linux and the video element in browsers. The system
//! decodes the video, in hardware where it can, and plays its sound in sync
//! with the picture; its frames reach the window's renderer where the
//! decoder left them, without a conversion on the CPU where the renderer
//! samples them there (`ui.VideoImage`).
//!
//!     const trailer_mp4 = @embedFile("trailer.mp4");
//!     var trailer = try video.openData(allocator, &host, trailer_mp4);
//!     defer trailer.deinit();
//!     ...
//!     try trailer.show(v, .{ .fit = .contain, .alt = "Trailer" }, .{ .grow = 1 });
//!
//! A video opens at once and loads in the background: the player is not
//! ready, and its size is 0×0, until its first picture came, which draws a
//! frame of the window that shows it, as a change of its state does. What
//! formats play is the system's: H.264 and AAC in MP4 or MOV play on all of
//! them; HEVC, VP9 and AV1 where the system has their decoders, and HLS
//! streams on macOS and in browsers.
//!
//! Apps that do not import the module link none of it, and GStreamer loads
//! with the first video opened. GIFs play without it, decoded by
//! `ziggurat_view_video.GifDecoder`, on every system.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const view = @import("ziggurat_view");
const video = @import("ziggurat_view_video");
pub const Source = @import("source.zig").Source;

const backend = switch (builtin.os.tag) {
    .linux => @import("gstreamer.zig"),
    .macos => @import("avfoundation.zig"),
    else => if (zio.is_web) @import("web.zig") else struct {
        pub const Engine = struct {
            pub fn open(_: Source) !*Engine {
                return error.Unsupported;
            }
            pub fn engine(_: *Engine) video.Engine {
                unreachable;
            }
        };
    },
};

/// A clip for tests of engines and renderers: 1.2 s of H.264 at 10 fps,
/// 64×48, with silent AAC; 0.4 s red, then green, then blue
/// (scripts/make-video-clips.sh).
pub const test_clip = @embedFile("testdata/rgb.mp4");

/// `error.Unsupported` reports a system without a media framework that
/// plays video: a Linux without GStreamer 1.x and its base plugins, or a
/// system of none. An app may show a GIF in its place.
pub const Error = error{Unsupported};

/// Open a video file, playing once a view shows it. In browsers the path
/// is a URL relative to the page.
pub fn open(allocator: std.mem.Allocator, host: *view.Host, path: []const u8) !video.Player {
    if (zio.is_web) return openUrl(allocator, host, path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = try zio.realpath(std.Io.Dir.cwd(), path, &buffer);
    const url = try fileUrl(allocator, absolute);
    defer allocator.free(url);
    return openUrl(allocator, host, url);
}
/// Open a video at a URL: a file:, http: or https: URL, or an HLS playlist
/// (.m3u8) where the system streams them. It plays once a view shows it.
pub fn openUrl(allocator: std.mem.Allocator, host: *view.Host, url: []const u8) !video.Player {
    return play(allocator, host, .{ .url = url });
}
/// Open a video in memory, as one embedded in the app, without writing it
/// to a file: the system reads it from `bytes`, which stay as they are
/// while the player is open. It plays once a view shows it.
pub fn openData(allocator: std.mem.Allocator, host: *view.Host, bytes: []const u8) !video.Player {
    if (bytes.len == 0) return error.NoData;
    return play(allocator, host, .{ .data = bytes });
}
/// The engine that plays `source`, for `video.Player.initEngine`.
pub fn openEngine(source: Source) !video.Engine {
    const engine = try backend.Engine.open(source);
    return engine.engine();
}

fn play(allocator: std.mem.Allocator, host: *view.Host, source: Source) !video.Player {
    const engine = try openEngine(source);
    return video.Player.initEngine(allocator, host, engine) catch |err| {
        engine.vtable.close(engine.context);
        return err;
    };
}

/// The file: URL of an absolute path, its bytes outside the unreserved ones
/// escaped.
pub fn fileUrl(allocator: std.mem.Allocator, absolute: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    // C:\… on Windows is /C:/….
    if (absolute.len > 0 and absolute[0] != '/' and absolute[0] != '\\') try out.append(allocator, '/');
    const hex = "0123456789ABCDEF";
    for (absolute) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '-', '_', '.', '~', ':' => try out.append(allocator, c),
        '\\' => try out.append(allocator, '/'),
        else => try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 15] }),
    };
    return out.toOwnedSlice(allocator);
}

test "file URLs escape what is not a path's own" {
    const url = try fileUrl(std.testing.allocator, "/tmp/a video #1.mp4");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///tmp/a%20video%20%231.mp4", url);
    const windows = try fileUrl(std.testing.allocator, "C:\\Videos\\clip.mp4");
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("file:///C:/Videos/clip.mp4", windows);
}

test {
    _ = @import("tests.zig");
}
