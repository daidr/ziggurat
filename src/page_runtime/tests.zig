const std = @import("std");
const ipc = @import("ziggurat_ipc");
const i18n = @import("ziggurat_i18n");
const runtime = @import("root.zig");
const allocator = std.testing.allocator;

const Page = struct {
    packets: std.ArrayList([]u8) = .empty,
    fail: bool = false,

    fn deinit(self: *Page) void {
        for (self.packets.items) |packet| allocator.free(packet);
        self.packets.deinit(allocator);
    }
    fn send(context: *anyopaque, bytes: []const u8) !void {
        const self: *Page = @ptrCast(@alignCast(context));
        if (self.fail) return error.TransportFailed;
        try self.packets.append(allocator, try allocator.dupe(u8, bytes));
    }
    fn transport(self: *Page) runtime.Transport {
        return .{ .context = self, .send = send };
    }
    fn last(self: *Page) []const u8 {
        return self.packets.items[self.packets.items.len - 1];
    }
    fn parsedLast(self: *Page) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, self.last(), .{});
    }
};

const Window = struct {
    maximized: bool = false,
    title: [32]u8 = undefined,
    title_len: usize = 0,
    closes: usize = 0,
    packets_at_close: usize = 0,
    page: ?*Page = null,
    fail_next: ?anyerror = null,

    fn of(context: *anyopaque) *Window {
        return @ptrCast(@alignCast(context));
    }
    fn check(self: *Window) !void {
        if (self.fail_next) |err| {
            self.fail_next = null;
            return err;
        }
    }
    fn minimize(context: *anyopaque) !void {
        try of(context).check();
    }
    fn maximize(context: *anyopaque) !void {
        try of(context).check();
        of(context).maximized = true;
    }
    fn unmaximize(context: *anyopaque) !void {
        of(context).maximized = false;
    }
    fn toggleMaximize(context: *anyopaque) !void {
        of(context).maximized = !of(context).maximized;
    }
    fn isMaximized(context: *anyopaque) !bool {
        return of(context).maximized;
    }
    fn toggleFullScreen(_: *anyopaque) !void {}
    fn close(context: *anyopaque) !void {
        const self = of(context);
        self.closes += 1;
        self.packets_at_close = self.page.?.packets.items.len;
    }
    fn setTitle(context: *anyopaque, title: []const u8) !void {
        const self = of(context);
        @memcpy(self.title[0..title.len], title);
        self.title_len = title.len;
    }
    const vtable: runtime.Controls.VTable = .{
        .minimize = minimize,
        .maximize = maximize,
        .unmaximize = unmaximize,
        .toggleMaximize = toggleMaximize,
        .isMaximized = isMaximized,
        .toggleFullScreen = toggleFullScreen,
        .close = close,
        .setTitle = setTitle,
    };
    fn controls(self: *Window) runtime.Controls {
        return .{ .context = self, .vtable = &vtable };
    }
};

const Echo = struct {
    session: ?ipc.Session = null,
    opens: usize = 0,
    closes: usize = 0,
    received: usize = 0,

    fn open(context: *anyopaque, _: *runtime.Host, session: ipc.Session) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.session = session;
        self.opens += 1;
    }
    fn receive(context: *anyopaque, host: *runtime.Host, bytes: []const u8) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.received += 1;
        host.send(bytes) catch {};
    }
    fn close(context: *anyopaque, host: *runtime.Host) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.closes += 1;
        // Closing endpoints can no longer reach the document.
        std.debug.assert(!host.connected());
    }
    const vtable: runtime.Endpoint.VTable = .{ .open = open, .receive = receive, .close = close };
    fn plugin(self: *Echo) runtime.Plugin {
        return .{ .name = "echo", .endpoint = .{ .context = self, .vtable = &vtable } };
    }
};

const Fixture = struct {
    page: Page = .{},
    window: Window = .{},
    echo: Echo = .{},
    prng: std.Random.DefaultPrng = .init(7),
    host: runtime.Host = undefined,

    fn init(self: *Fixture) !void {
        self.window.page = &self.page;
        self.host = .init(allocator, .{
            .transport = self.page.transport(),
            .controls = self.window.controls(),
            .window_id = 3,
            .locale = try i18n.Locale.parse("en"),
            .random = self.prng.random(),
        });
        try self.host.use(self.echo.plugin());
    }
    fn deinit(self: *Fixture) void {
        self.host.detach();
        self.page.deinit();
    }
    fn session(self: *Fixture, name: []const u8) ![32]u8 {
        // The newest configuration in the page's inbox.
        var index = self.page.packets.items.len;
        while (index > 0) {
            index -= 1;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, self.page.packets.items[index], .{});
            defer parsed.deinit();
            const tag = parsed.value.object.get("ziggurat") orelse continue;
            if (!std.mem.eql(u8, tag.string, "runtime")) continue;
            const text = parsed.value.object.get("services").?.object.get(name).?.string;
            return text[0..32].*;
        }
        return error.NotConfigured;
    }
    fn call(self: *Fixture, id: u32, method: []const u8, params: anytype) !runtime.Received {
        const s = try self.session("runtime");
        const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &s, .kind = "call", .slot = 0, .id = id, .method = method, .params = params }, 65536);
        defer allocator.free(bytes);
        return self.host.receive(bytes);
    }
    fn control(self: *Fixture, kind: []const u8, event: []const u8, subscription: u32) !void {
        const s = try self.session("runtime");
        const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &s, .kind = kind, .event = event, .subscription = subscription }, 65536);
        defer allocator.free(bytes);
        try std.testing.expectEqual(.handled, self.host.receive(bytes));
    }
};

test "hello answers with the runtime configuration and fresh plugin sessions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(.handled, f.host.receive(runtime.hello));
    try std.testing.expect(f.host.connected());
    const parsed = try f.page.parsedLast();
    defer parsed.deinit();
    const config = parsed.value.object;
    try std.testing.expectEqual(1, config.get("v").?.integer);
    try std.testing.expectEqualStrings(@tagName(runtime.platform), config.get("platform").?.string);
    try std.testing.expectEqual(3, config.get("windowId").?.integer);
    try std.testing.expectEqualStrings(runtime.version, config.get("version").?.string);
    try std.testing.expectEqualStrings("en", config.get("locale").?.string);
    try std.testing.expectEqualStrings("ltr", config.get("dir").?.string);
    const preferences = config.get("preferences").?.object;
    try std.testing.expect(preferences.get("accent").? == .null);
    try std.testing.expectEqualStrings("unknown", preferences.get("colorScheme").?.string);
    const echo = try f.session("plugin:echo");
    try std.testing.expectEqualStrings(&f.echo.session.?.bytes, &echo);
    try std.testing.expect(!std.mem.eql(u8, &echo, &(try f.session("runtime"))));
    try std.testing.expectEqual(1, f.echo.opens);
}

test "foreign and stale messages are told apart" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(.foreign, f.host.receive("increment"));
    try std.testing.expectEqual(.foreign, f.host.receive("{\"ziggurat\":\"hello\"}"));
    const stale = "{\"v\":1,\"session\":\"0123456789abcdef0123456789abcdef\",\"kind\":\"call\"}";
    try std.testing.expectEqual(.handled, f.host.receive(stale));
    try std.testing.expectEqual(0, f.page.packets.items.len);
    _ = f.host.receive(runtime.hello);
    try std.testing.expectEqual(.handled, f.host.receive(stale));
    try std.testing.expectEqual(.foreign, f.host.receive("{\"v\":1,\"session\":\"0123456789ABCDEF0123456789abcdef\"}"));
    try std.testing.expectEqual(1, f.page.packets.items.len);
}

test "window calls reply with results and declared failures" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.host.receive(runtime.hello);
    try std.testing.expectEqual(.handled, try f.call(1, "setTitle", .{ .title = "Notes" }));
    try std.testing.expectEqualStrings("Notes", f.window.title[0..f.window.title_len]);
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "\"kind\":\"result\"") != null);
    _ = try f.call(2, "toggleMaximize", null);
    _ = try f.call(3, "isMaximized", null);
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "\"value\":true") != null);
    f.window.fail_next = error.InvalidWindowState;
    _ = try f.call(4, "minimize", null);
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "\"code\":\"invalid_state\"") != null);
    f.window.fail_next = error.Closed;
    _ = try f.call(5, "maximize", null);
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "\"code\":\"unavailable\"") != null);
    _ = try f.call(6, "setTitle", .{ .wrong = 1 });
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "\"kind\":\"reject\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.page.last(), "invalid_params") != null);
}

test "closing the window replies before the window closes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.host.receive(runtime.hello);
    const before = f.page.packets.items.len;
    _ = try f.call(1, "closeWindow", null);
    try std.testing.expectEqual(1, f.window.closes);
    try std.testing.expectEqual(before + 1, f.window.packets_at_close);
}

test "events reach only subscribed documents and later documents start current" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expect(!try f.host.setLocale(try i18n.Locale.parse("de")));
    _ = f.host.receive(runtime.hello);
    try std.testing.expect(!try f.host.setLocale(try i18n.Locale.parse("ar-EG")));
    try f.control("subscribe", "locale", 1);
    try f.control("subscribe", "preferences", 2);
    try std.testing.expect(try f.host.setLocale(try i18n.Locale.parse("he")));
    var parsed = try f.page.parsedLast();
    try std.testing.expectEqualStrings("locale", parsed.value.object.get("event").?.string);
    try std.testing.expectEqualStrings("rtl", parsed.value.object.get("value").?.object.get("dir").?.string);
    parsed.deinit();
    try std.testing.expect(try f.host.setPreferences(.{ .accent = 0x0a84ff, .high_contrast = true, .text_scale = 1.25 }));
    parsed = try f.page.parsedLast();
    const value = parsed.value.object.get("value").?.object;
    try std.testing.expectEqualStrings("#0a84ff", value.get("accent").?.string);
    try std.testing.expect(value.get("highContrast").?.bool);
    try std.testing.expect(!value.get("reduceTransparency").?.bool);
    parsed.deinit();
    try std.testing.expect(!try f.host.fileDrop(&.{"/tmp/a.txt"}, 4, 5));
    try f.control("subscribe", "fileDrop", 3);
    try std.testing.expect(try f.host.fileDrop(&.{ "/tmp/a.txt", "/tmp/b" }, 4, 5));
    try f.control("unsubscribe", "fileDrop", 3);
    try std.testing.expect(!try f.host.fileDrop(&.{"/tmp/a.txt"}, 4, 5));
    _ = f.host.receive(runtime.hello);
    parsed = try f.page.parsedLast();
    defer parsed.deinit();
    try std.testing.expectEqualStrings("he", parsed.value.object.get("locale").?.string);
    try std.testing.expectEqualStrings("#0a84ff", parsed.value.object.get("preferences").?.object.get("accent").?.string);
    try std.testing.expect(!try f.host.setLocale(try i18n.Locale.parse("en")));
}

test "invalid subscription controls end the connection" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.host.receive(runtime.hello);
    try f.control("subscribe", "missing", 1);
    try std.testing.expect(!f.host.connected());
    try std.testing.expectEqual(1, f.echo.closes);
}

test "a new document cancels the old one's sessions" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.host.receive(runtime.hello);
    const old_runtime = try f.session("runtime");
    const old_echo = try f.session("plugin:echo");
    _ = f.host.receive(runtime.hello);
    try std.testing.expectEqual(1, f.echo.closes);
    try std.testing.expectEqual(2, f.echo.opens);
    try std.testing.expect(!std.mem.eql(u8, &old_runtime, &(try f.session("runtime"))));
    const packets = f.page.packets.items.len;
    const stale = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &old_runtime, .kind = "call", .slot = 0, .id = 1, .method = "minimize" }, 65536);
    defer allocator.free(stale);
    try std.testing.expectEqual(.handled, f.host.receive(stale));
    const stale_echo = try std.fmt.allocPrint(allocator, "{{\"v\":1,\"session\":\"{s}\",\"kind\":\"call\"}}", .{&old_echo});
    defer allocator.free(stale_echo);
    try std.testing.expectEqual(.handled, f.host.receive(stale_echo));
    try std.testing.expectEqual(packets, f.page.packets.items.len);
    try std.testing.expectEqual(0, f.echo.received);
    const current = try std.fmt.allocPrint(allocator, "{{\"v\":1,\"session\":\"{s}\",\"kind\":\"call\"}}", .{&(try f.session("plugin:echo"))});
    defer allocator.free(current);
    try std.testing.expectEqual(.handled, f.host.receive(current));
    try std.testing.expectEqual(1, f.echo.received);
    try std.testing.expectEqualStrings(current, f.page.last());
}

test "a transport failure closes the connection until the next hello" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    _ = f.host.receive(runtime.hello);
    try f.control("subscribe", "documentReload", 1);
    f.page.fail = true;
    try std.testing.expectError(error.TransportFailed, f.host.documentReload());
    try std.testing.expect(!f.host.connected());
    try std.testing.expectEqual(1, f.echo.closes);
    try std.testing.expect(!try f.host.documentReload());
    f.page.fail = false;
    _ = f.host.receive(runtime.hello);
    try std.testing.expect(f.host.connected());
    f.host.detach();
    try std.testing.expectEqual(2, f.echo.closes);
    try std.testing.expectEqual(.handled, f.host.receive(runtime.hello));
    try std.testing.expect(!f.host.connected());
    try std.testing.expectError(error.Closed, f.host.use(f.echo.plugin()));
}

test "plugins need valid distinct names" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectError(error.DuplicateName, f.host.use(f.echo.plugin()));
    var other = f.echo.plugin();
    for ([_][]const u8{ "", "Echo", "1echo", "echo_two", "a" ** 33 }) |name| {
        other.name = name;
        try std.testing.expectError(error.InvalidName, f.host.use(other));
    }
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o" };
    for (names) |name| try f.host.use(.{ .name = name, .endpoint = other.endpoint });
    try std.testing.expectError(error.Full, f.host.use(.{ .name = "p", .endpoint = other.endpoint }));
}

test "desktop preferences convert by field name" {
    const Desktop = struct {
        color_scheme: enum { light, dark, unknown } = .dark,
        accent: ?u32 = 0x123456,
        high_contrast: bool = false,
        reduce_motion: bool = true,
        reduce_transparency: ?bool = true,
        text_scale: f32 = 2,
    };
    const value = runtime.Preferences.fromDesktop(Desktop{});
    try std.testing.expectEqual(.dark, value.color_scheme);
    try std.testing.expectEqual(0x123456, value.accent.?);
    try std.testing.expect(value.reduce_motion and value.reduce_transparency.?);
}
