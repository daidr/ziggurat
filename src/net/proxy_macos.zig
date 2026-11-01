//! macOS reads the user's settings (System Settings > Network > Details >
//! Proxies) with CFNetwork, as Safari and URLSession do: the manual HTTP,
//! HTTPS and SOCKS proxies with their bypass list, automatic proxy
//! discovery (WPAD) and setup scripts (PAC files). A setup script runs on
//! the calling thread's run loop, in a private mode, for at most 5 seconds.
const std = @import("std");
const zio = @import("ziggurat_io");
const proxy = @import("proxy.zig");

const CFTypeRef = *const anyopaque;
const CFStringRef = *const opaque {};
const CFArrayRef = *const opaque {};
const CFDictionaryRef = *const opaque {};
const CFURLRef = *const opaque {};
const CFNumberRef = *const opaque {};
const CFErrorRef = *const opaque {};
const CFRunLoopRef = *opaque {};
const CFRunLoopSourceRef = *opaque {};
const CFIndex = isize;

const utf8_encoding: u32 = 0x08000100;
const number_int_type: CFIndex = 9; // kCFNumberIntType

/// CFStreamClientContext.
const ClientContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

const ResultCallback = *const fn (client: ?*anyopaque, list: ?CFArrayRef, err: ?CFErrorRef) callconv(.c) void;

extern "c" fn CFRelease(value: CFTypeRef) void;
extern "c" fn CFRetain(value: CFTypeRef) CFTypeRef;
extern "c" fn CFEqual(a: CFTypeRef, b: CFTypeRef) u8;
extern "c" fn CFArrayGetCount(array: CFArrayRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) ?CFTypeRef;
extern "c" fn CFDictionaryGetValue(dictionary: CFDictionaryRef, key: CFTypeRef) ?CFTypeRef;
extern "c" fn CFStringGetCString(string: CFStringRef, buffer: [*]u8, size: CFIndex, encoding: u32) u8;
extern "c" fn CFStringCreateWithBytes(allocator: ?*const anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: u8) ?CFStringRef;
extern "c" fn CFNumberGetValue(number: CFNumberRef, kind: CFIndex, out: *anyopaque) u8;
extern "c" fn CFURLCreateWithBytes(allocator: ?*const anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, base: ?CFURLRef) ?CFURLRef;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRemoveSource(loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRunInMode(mode: CFStringRef, seconds: f64, return_after_source: u8) i32;
extern "c" fn CFRunLoopSourceInvalidate(source: CFRunLoopSourceRef) void;
extern "c" fn CFNetworkCopySystemProxySettings() ?CFDictionaryRef;
extern "c" fn CFNetworkCopyProxiesForURL(url: CFURLRef, settings: CFDictionaryRef) ?CFArrayRef;
extern "c" fn CFNetworkExecuteProxyAutoConfigurationURL(script_url: CFURLRef, target: CFURLRef, callback: ResultCallback, context: *ClientContext) ?CFRunLoopSourceRef;
extern "c" fn CFNetworkExecuteProxyAutoConfigurationScript(script: CFStringRef, target: CFURLRef, callback: ResultCallback, context: *ClientContext) ?CFRunLoopSourceRef;

extern const kCFProxyTypeKey: CFStringRef;
extern const kCFProxyHostNameKey: CFStringRef;
extern const kCFProxyPortNumberKey: CFStringRef;
extern const kCFProxyUsernameKey: CFStringRef;
extern const kCFProxyPasswordKey: CFStringRef;
extern const kCFProxyAutoConfigurationURLKey: CFStringRef;
extern const kCFProxyAutoConfigurationJavaScriptKey: CFStringRef;
extern const kCFProxyTypeNone: CFStringRef;
extern const kCFProxyTypeHTTP: CFStringRef;
extern const kCFProxyTypeHTTPS: CFStringRef;
extern const kCFProxyTypeSOCKS: CFStringRef;
extern const kCFProxyTypeAutoConfigurationURL: CFStringRef;
extern const kCFProxyTypeAutoConfigurationJavaScript: CFStringRef;

const pac_timeout_seconds = 5.0;

pub fn system(url: []const u8) ?proxy.Proxy {
    const target = CFURLCreateWithBytes(null, url.ptr, @intCast(url.len), utf8_encoding, null) orelse return null;
    defer CFRelease(target);
    const settings = CFNetworkCopySystemProxySettings() orelse return null;
    defer CFRelease(settings);
    const list = CFNetworkCopyProxiesForURL(target, settings) orelse return null;
    defer CFRelease(list);
    return choose(list, target, true).proxy;
}

const Answer = struct {
    /// Whether the list decided: a usable proxy, or a direct connection.
    decided: bool = false,
    proxy: ?proxy.Proxy = null,
};

/// The first entry of `list` that can be used, running a setup script it
/// names when `scripts` (a script's own answer never names another).
fn choose(list: CFArrayRef, target: CFURLRef, scripts: bool) Answer {
    const count = CFArrayGetCount(list);
    var index: CFIndex = 0;
    while (index < count) : (index += 1) {
        const entry: CFDictionaryRef = @ptrCast(CFArrayGetValueAtIndex(list, index) orelse continue);
        const kind: CFTypeRef = CFDictionaryGetValue(entry, kCFProxyTypeKey) orelse continue;
        if (CFEqual(kind, kCFProxyTypeNone) != 0) return .{ .decided = true };
        if (CFEqual(kind, kCFProxyTypeHTTP) != 0 or CFEqual(kind, kCFProxyTypeHTTPS) != 0) {
            if (server(entry, "http")) |value| return .{ .decided = true, .proxy = value };
        } else if (CFEqual(kind, kCFProxyTypeSOCKS) != 0) {
            if (server(entry, "socks5")) |value| return .{ .decided = true, .proxy = value };
        } else if (scripts and CFEqual(kind, kCFProxyTypeAutoConfigurationURL) != 0) {
            const script_url: CFURLRef = @ptrCast(CFDictionaryGetValue(entry, kCFProxyAutoConfigurationURLKey) orelse continue);
            const answer = runScript(.{ .url = script_url }, target);
            if (answer.decided) return answer;
        } else if (scripts and CFEqual(kind, kCFProxyTypeAutoConfigurationJavaScript) != 0) {
            const script: CFStringRef = @ptrCast(CFDictionaryGetValue(entry, kCFProxyAutoConfigurationJavaScriptKey) orelse continue);
            const answer = runScript(.{ .script = script }, target);
            if (answer.decided) return answer;
        }
    }
    return .{};
}

const Script = union(enum) { url: CFURLRef, script: CFStringRef };

const Run = struct {
    target: CFURLRef,
    done: bool = false,
    answer: Answer = .{},

    fn finished(client: ?*anyopaque, list: ?CFArrayRef, err: ?CFErrorRef) callconv(.c) void {
        const self: *Run = @ptrCast(@alignCast(client.?));
        self.done = true;
        if (err != null) return;
        if (list) |value| self.answer = choose(value, self.target, false);
    }
};

/// Runs a setup script for `target` on this thread's run loop; a script
/// that fails or does not answer in time leaves the decision to the next
/// entry.
fn runScript(script: Script, target: CFURLRef) Answer {
    var run: Run = .{ .target = target };
    var context: ClientContext = .{ .info = &run };
    const source = switch (script) {
        .url => |value| CFNetworkExecuteProxyAutoConfigurationURL(value, target, Run.finished, &context),
        .script => |value| CFNetworkExecuteProxyAutoConfigurationScript(value, target, Run.finished, &context),
    } orelse return .{};
    defer CFRelease(source);
    const mode_name = "dev.ziggurat.proxy-script";
    const mode = CFStringCreateWithBytes(null, mode_name.ptr, mode_name.len, utf8_encoding, 0) orelse return .{};
    defer CFRelease(mode);
    const loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(loop, source, mode);
    defer {
        CFRunLoopRemoveSource(loop, source, mode);
        CFRunLoopSourceInvalidate(source);
    }
    const start = zio.nanoTimestamp();
    while (!run.done) {
        const elapsed: f64 = @as(f64, @floatFromInt(zio.nanoTimestamp() - start)) / std.time.ns_per_s;
        if (elapsed >= pac_timeout_seconds) break;
        _ = CFRunLoopRunInMode(mode, pac_timeout_seconds - elapsed, 1);
    }
    return run.answer;
}

/// The proxy of a manual or script entry, as `scheme://user:password@host:port`
/// parsed by proxy.parse.
fn server(entry: CFDictionaryRef, scheme: []const u8) ?proxy.Proxy {
    var host_buffer: [256]u8 = undefined;
    const host_name = text(CFDictionaryGetValue(entry, kCFProxyHostNameKey), &host_buffer) orelse return null;
    if (host_name.len == 0) return null;
    var port: c_int = 0;
    if (CFDictionaryGetValue(entry, kCFProxyPortNumberKey)) |number| _ = CFNumberGetValue(@ptrCast(number), number_int_type, &port);
    if (port <= 0 or port > 65535) port = if (std.mem.eql(u8, scheme, "http")) 80 else 1080;
    var user_buffer: [256]u8 = undefined;
    var password_buffer: [256]u8 = undefined;
    const user = text(CFDictionaryGetValue(entry, kCFProxyUsernameKey), &user_buffer);
    const password = text(CFDictionaryGetValue(entry, kCFProxyPasswordKey), &password_buffer);
    var out_buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    out.print("{s}://", .{scheme}) catch return null;
    if (user) |name| if (name.len > 0) {
        escape(&out, name) catch return null;
        out.writeByte(':') catch return null;
        escape(&out, password orelse "") catch return null;
        out.writeByte('@') catch return null;
    };
    const bracket = std.mem.indexOfScalar(u8, host_name, ':') != null;
    out.print("{s}{s}{s}:{d}", .{ if (bracket) "[" else "", host_name, if (bracket) "]" else "", port }) catch return null;
    return proxy.Proxy.parse(out.buffered());
}

fn text(value: ?CFTypeRef, buffer: []u8) ?[]const u8 {
    const string: CFStringRef = @ptrCast(value orelse return null);
    if (CFStringGetCString(string, buffer.ptr, @intCast(buffer.len), utf8_encoding) == 0) return null;
    return std.mem.sliceTo(buffer, 0);
}

fn escape(out: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~')
            try out.writeByte(byte)
        else
            try out.print("%{X:0>2}", .{byte});
    }
}

test "macOS setup scripts answer with their first usable proxy" {
    const url = "https://example.test/";
    const target = CFURLCreateWithBytes(null, url.ptr, url.len, utf8_encoding, null).?;
    defer CFRelease(target);
    const source = "function FindProxyForURL(url, host) { return host == 'example.test' ? 'PROXY p.test:3128; DIRECT' : 'DIRECT'; }";
    const script = CFStringCreateWithBytes(null, source.ptr, source.len, utf8_encoding, 0).?;
    defer CFRelease(script);
    const answer = runScript(.{ .script = script }, target);
    try std.testing.expect(answer.decided);
    const value = answer.proxy.?;
    try std.testing.expectEqual(proxy.Kind.http, value.kind);
    try std.testing.expectEqualStrings("p.test", value.host());
    try std.testing.expectEqual(@as(u16, 3128), value.port);

    const direct = "function FindProxyForURL(url, host) { return 'DIRECT'; }";
    const direct_script = CFStringCreateWithBytes(null, direct.ptr, direct.len, utf8_encoding, 0).?;
    defer CFRelease(direct_script);
    const none = runScript(.{ .script = direct_script }, target);
    try std.testing.expect(none.decided and none.proxy == null);
    // The user's own settings answer without failing, whatever they hold.
    _ = system(url);
}
