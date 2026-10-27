//! Windows reads the user's settings (Settings > Network & internet >
//! Proxy, the Internet Options of old) with WinHTTP: automatic detection
//! (WPAD) and setup scripts (PAC files) first, then the manual proxy and its
//! bypass list. WinHTTP is loaded from the system directory on first use.
const std = @import("std");
const windows = std.os.windows;
const proxy = @import("proxy.zig");

const BOOL = windows.BOOL;
const LPWSTR = ?[*:0]u16;

/// WINHTTP_CURRENT_USER_IE_PROXY_CONFIG. Its strings are the caller's, freed
/// with GlobalFree.
const IeProxyConfig = extern struct {
    auto_detect: BOOL,
    auto_config_url: LPWSTR,
    proxy: LPWSTR,
    proxy_bypass: LPWSTR,
};

/// WINHTTP_AUTOPROXY_OPTIONS.
const AutoProxyOptions = extern struct {
    flags: u32,
    auto_detect_flags: u32,
    auto_config_url: ?[*:0]const u16,
    reserved1: ?*anyopaque = null,
    reserved2: u32 = 0,
    auto_logon_if_challenged: BOOL,
};

/// WINHTTP_PROXY_INFO. Its strings are the caller's, freed with GlobalFree.
const ProxyInfo = extern struct {
    access_type: u32,
    proxy: LPWSTR,
    proxy_bypass: LPWSTR,
};

const access_type_no_proxy = 1;
const access_type_named_proxy = 3;
const autoproxy_auto_detect = 0x1;
const autoproxy_config_url = 0x2;
const auto_detect_type_dhcp = 0x1;
const auto_detect_type_dns_a = 0x2;
const load_library_search_system32 = 0x800;

const Api = struct {
    ie_config: *const fn (*IeProxyConfig) callconv(.winapi) BOOL,
    open: *const fn (?[*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?*anyopaque,
    set_timeouts: *const fn (*anyopaque, c_int, c_int, c_int, c_int) callconv(.winapi) BOOL,
    proxy_for_url: *const fn (*anyopaque, [*:0]const u16, *AutoProxyOptions, *ProxyInfo) callconv(.winapi) BOOL,
    session: ?*anyopaque,
};

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

var once = std.once(load);
var api: ?Api = null;

/// Loads WinHTTP from the system directory, never from the app's directory
/// or the search path, and opens a synchronous session for setup scripts,
/// kept for the process.
fn load() void {
    const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("winhttp.dll"), null, load_library_search_system32) orelse return;
    var value: Api = .{
        .ie_config = @ptrCast(GetProcAddress(module, "WinHttpGetIEProxyConfigForCurrentUser") orelse return),
        .open = @ptrCast(GetProcAddress(module, "WinHttpOpen") orelse return),
        .set_timeouts = @ptrCast(GetProcAddress(module, "WinHttpSetTimeouts") orelse return),
        .proxy_for_url = @ptrCast(GetProcAddress(module, "WinHttpGetProxyForUrl") orelse return),
        .session = null,
    };
    value.session = value.open(std.unicode.utf8ToUtf16LeStringLiteral("ziggurat"), access_type_no_proxy, null, null, 0);
    // Bounds fetching a setup script, which may not answer.
    if (value.session) |session| _ = value.set_timeouts(session, 5000, 5000, 5000, 5000);
    api = value;
}

/// Text of a string WinHTTP allocated, as UTF-8 in `out`; frees it.
fn take(text: LPWSTR, out: []u8) []const u8 {
    const value = text orelse return "";
    defer _ = GlobalFree(value);
    const length = std.unicode.calcWtf8Len(std.mem.span(value));
    if (length > out.len) return "";
    return out[0..std.unicode.wtf16LeToWtf8(out, std.mem.span(value))];
}

pub fn system(url: []const u8, secure: bool, host_name: []const u8) ?proxy.Proxy {
    once.call();
    const winhttp = api orelse return null;
    var config: IeProxyConfig = .{ .auto_detect = 0, .auto_config_url = null, .proxy = null, .proxy_bypass = null };
    if (winhttp.ie_config(&config) == 0) return null;
    var pac_buffer: [2048]u8 = undefined;
    var proxy_buffer: [2048]u8 = undefined;
    var bypass_buffer: [4096]u8 = undefined;
    const pac = take(config.auto_config_url, &pac_buffer);
    const list = take(config.proxy, &proxy_buffer);
    const bypass = take(config.proxy_bypass, &bypass_buffer);
    if (config.auto_detect != 0 or pac.len > 0) {
        if (automatic(winhttp, url, config.auto_detect != 0, pac, secure, host_name)) |answer| return answer.proxy;
    }
    return proxy.windowsStatic(list, bypass, secure, host_name);
}

const Answer = struct { proxy: ?proxy.Proxy };

/// Runs the setup script, the one detection finds or the one at `pac`. Null
/// when there is none or it fails.
fn automatic(winhttp: Api, url: []const u8, detect: bool, pac: []const u8, secure: bool, host_name: []const u8) ?Answer {
    const session = winhttp.session orelse return null;
    var options: AutoProxyOptions = .{ .flags = 0, .auto_detect_flags = 0, .auto_config_url = null, .auto_logon_if_challenged = 1 };
    if (detect) {
        options.flags |= autoproxy_auto_detect;
        options.auto_detect_flags = auto_detect_type_dhcp | auto_detect_type_dns_a;
    }
    var pac_wide: [2048:0]u16 = undefined;
    if (pac.len > 0) {
        const length = std.unicode.utf8ToUtf16Le(&pac_wide, pac) catch return null;
        pac_wide[length] = 0;
        options.flags |= autoproxy_config_url;
        options.auto_config_url = pac_wide[0..length :0];
    }
    var url_wide: [std.Uri.host_name_max + 64:0]u16 = undefined;
    const url_length = std.unicode.utf8ToUtf16Le(&url_wide, url) catch return null;
    url_wide[url_length] = 0;
    var info: ProxyInfo = .{ .access_type = 0, .proxy = null, .proxy_bypass = null };
    if (winhttp.proxy_for_url(session, url_wide[0..url_length :0], &options, &info) == 0) return null;
    var proxy_buffer: [2048]u8 = undefined;
    var bypass_buffer: [4096]u8 = undefined;
    const list = take(info.proxy, &proxy_buffer);
    const bypass = take(info.proxy_bypass, &bypass_buffer);
    if (info.access_type != access_type_named_proxy) return .{ .proxy = null };
    return .{ .proxy = proxy.windowsStatic(list, bypass, secure, host_name) };
}
