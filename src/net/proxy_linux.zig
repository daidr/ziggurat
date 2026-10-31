//! Linux asks GIO's default proxy resolver, as WebKitGTK does: GNOME's
//! settings, KDE's and PAC files through libproxy, the desktop portal in a
//! sandbox. GIO is loaded on first use, so apps that never make a request
//! through a proxy decision do not load it; without GIO, requests go direct.
const std = @import("std");
const zio = @import("ziggurat_io");
const proxy = @import("proxy.zig");

const Api = struct {
    get_default: *const fn () callconv(.c) ?*anyopaque,
    lookup: *const fn (resolver: *anyopaque, uri: [*:0]const u8, cancellable: ?*anyopaque, err: *?*anyopaque) callconv(.c) ?[*:null]?[*:0]u8,
    strfreev: *const fn (list: ?[*:null]?[*:0]u8) callconv(.c) void,
    error_free: *const fn (err: *anyopaque) callconv(.c) void,
};

var once = zio.once(load);
var api: ?Api = null;

fn load() void {
    const library = std.c.dlopen("libgio-2.0.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return;
    api = .{
        .get_default = @ptrCast(std.c.dlsym(library, "g_proxy_resolver_get_default") orelse return),
        .lookup = @ptrCast(std.c.dlsym(library, "g_proxy_resolver_lookup") orelse return),
        // GLib's functions are found through GIO, which links it.
        .strfreev = @ptrCast(std.c.dlsym(library, "g_strfreev") orelse return),
        .error_free = @ptrCast(std.c.dlsym(library, "g_error_free") orelse return),
    };
}

pub fn system(url: []const u8) ?proxy.Proxy {
    once.call();
    const gio = api orelse return null;
    var url_buffer: [std.Io.net.HostName.max_len + 64]u8 = undefined;
    if (url.len >= url_buffer.len) return null;
    @memcpy(url_buffer[0..url.len], url);
    url_buffer[url.len] = 0;
    // Not owned.
    const resolver = gio.get_default() orelse return null;
    var err: ?*anyopaque = null;
    const list = gio.lookup(resolver, url_buffer[0..url.len :0], null, &err) orelse {
        if (err) |value| gio.error_free(value);
        return null;
    };
    defer gio.strfreev(list);
    var items: [16][]const u8 = undefined;
    var count: usize = 0;
    while (list[count]) |item| : (count += 1) {
        if (count == items.len) break;
        items[count] = std.mem.span(item);
    }
    return proxy.firstSupported(items[0..count]);
}
