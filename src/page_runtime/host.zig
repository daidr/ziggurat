const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ziggurat_ipc");
const i18n = @import("ziggurat_i18n");
const service = @import("service.zig");
const Controls = @import("controls.zig").Controls;

pub const version = "0.1.0-dev";
/// Wire version of the handshake; independent of the IPC protocol version.
pub const handshake_version = 1;
pub const max_plugins = 16;
pub const max_name_bytes = 32;
pub const limits: ipc.Limits = .{};
pub const event_limits: ipc.EventLimits = .{};
/// The exact message a page sends to (re)connect its document.
pub const hello = "{\"ziggurat\":\"hello\",\"v\":1}";

pub const Platform = enum { win32, linux, darwin };
pub const platform: Platform = switch (builtin.os.tag) {
    .windows => .win32,
    .macos => .darwin,
    else => .linux,
};

/// Delivers one owned host-to-page message. Bytes are borrowed for the call;
/// an error means the message was not accepted.
pub const Transport = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// A service connected through the Host, such as a plugin's. Every call runs on
/// the main thread inside Host.receive, use or pageChanged/detach.
pub const Endpoint = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// A new document connected with this fresh session. Cancel work of any
        /// earlier session before accepting the new one.
        open: *const fn (*anyopaque, *Host, ipc.Session) void,
        /// One message addressed to the current session; bytes are borrowed.
        receive: *const fn (*anyopaque, *Host, []const u8) void,
        /// The document is gone: cancel work and stop sending until open.
        close: *const fn (*anyopaque, *Host) void,
    };
};

/// A named service that pages reach as "plugin:<name>".
pub const Plugin = struct {
    /// 1-32 bytes of lowercase ASCII letters, digits and dashes, starting with a letter.
    name: []const u8,
    endpoint: Endpoint,
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.ascii.isLower(name[0])) return false;
    for (name) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}

/// Desktop preferences in host form; `fromDesktop` copies the fields of the
/// system module's Preferences without importing it.
pub const Preferences = struct {
    color_scheme: service.ColorScheme = .unknown,
    /// 0xRRGGBB, null when the platform has no accent color.
    accent: ?u32 = null,
    high_contrast: bool = false,
    reduce_motion: bool = false,
    reduce_transparency: ?bool = null,
    text_scale: f32 = 1,

    pub fn fromDesktop(value: anytype) Preferences {
        return .{
            .color_scheme = std.meta.stringToEnum(service.ColorScheme, @tagName(value.color_scheme)) orelse .unknown,
            .accent = value.accent,
            .high_contrast = value.high_contrast,
            .reduce_motion = value.reduce_motion,
            .reduce_transparency = value.reduce_transparency,
            .text_scale = value.text_scale,
        };
    }

    fn wire(self: Preferences, accent: *[7]u8) service.Preferences {
        const text = if (self.accent) |color| std.fmt.bufPrint(accent, "#{x:0>6}", .{color & 0xffffff}) catch unreachable else null;
        return .{
            .accent = text,
            .colorScheme = self.color_scheme,
            .reduceMotion = self.reduce_motion,
            .reduceTransparency = self.reduce_transparency orelse false,
            .highContrast = self.high_contrast,
            .textScale = if (std.math.isFinite(self.text_scale) and self.text_scale > 0) self.text_scale else 1,
        };
    }
};

pub const Options = struct {
    transport: Transport,
    controls: Controls,
    /// Identifies the hosting window to the page; unique among open windows.
    window_id: u32 = 0,
    version: []const u8 = version,
    locale: i18n.Locale = i18n.Locale.parse("en") catch unreachable,
    preferences: Preferences = .{},
    /// Session source; null uses the operating system's CSPRNG.
    random: ?std.Random = null,
};

pub const Received = enum {
    /// A runtime message: handled, or dropped as stale or invalid.
    handled,
    /// Not a runtime message; the application handles it.
    foreign,
};

pub const State = enum { waiting, connected, detached };

const Impl = struct {
    fn window(host: *Host, comptime op: []const u8) ipc.Reply(service.Service, op) {
        @field(host.controls.vtable, op)(host.controls.context) catch |err| return failure(service.Service, op, err);
        return .{ .result = {} };
    }
    pub fn minimize(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "minimize") {
        return window(host, "minimize");
    }
    pub fn maximize(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "maximize") {
        return window(host, "maximize");
    }
    pub fn unmaximize(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "unmaximize") {
        return window(host, "unmaximize");
    }
    pub fn toggleMaximize(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "toggleMaximize") {
        return window(host, "toggleMaximize");
    }
    pub fn toggleFullScreen(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "toggleFullScreen") {
        return window(host, "toggleFullScreen");
    }
    pub fn isMaximized(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "isMaximized") {
        const value = host.controls.vtable.isMaximized(host.controls.context) catch |err| return failure(service.Service, "isMaximized", err);
        return .{ .result = value };
    }
    pub fn closeWindow(_: *Impl, host: *Host, _: void) ipc.Reply(service.Service, "closeWindow") {
        // Reply first: closing can detach the page that is waiting for it.
        host.close_requested = true;
        return .{ .result = {} };
    }
    pub fn setTitle(_: *Impl, host: *Host, params: service.Service.methods.setTitle.Params) ipc.Reply(service.Service, "setTitle") {
        host.controls.vtable.setTitle(host.controls.context, params.title) catch |err| return failure(service.Service, "setTitle", err);
        return .{ .result = {} };
    }
};

fn failure(comptime S: type, comptime op: []const u8, err: anyerror) ipc.Reply(S, op) {
    const code: service.WindowError = switch (err) {
        error.InvalidWindowState, error.ModalBlocked, error.Disabled, error.Busy => .invalid_state,
        else => .unavailable,
    };
    return .{ .failure = .{ .code = code, .message = @errorName(err) } };
}

const Dispatch = ipc.Dispatcher(service.Service, Impl, Host, limits);
const Events = ipc.EventSession(service.Service, event_limits);
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;

/// Connects one page document to the built-in runtime service and the
/// application's plugins over a caller-owned transport. Main thread only;
/// keep the Host at a stable address from init to detach. It does not
/// allocate except through the allocator passed to receive and emit.
pub const Host = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    controls: Controls,
    random: std.Random,
    window_id: u32,
    version: []const u8,
    locale: i18n.Locale,
    preferences: Preferences,
    plugins: [max_plugins]Plugin = undefined,
    sessions: [max_plugins]ipc.Session = undefined,
    plugin_count: usize = 0,
    state: State = .waiting,
    runtime: Dispatch = .init(unset),
    events: Events = .init(unset),
    implementation: Impl = .{},
    close_requested: bool = false,
    /// The most recent dropped message or failed delivery, for diagnostics.
    last_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) Host {
        var host: Host = .{
            .allocator = allocator,
            .transport = options.transport,
            .controls = options.controls,
            .random = options.random orelse std.crypto.random,
            .window_id = options.window_id,
            .version = options.version,
            .locale = options.locale,
            .preferences = options.preferences,
        };
        host.runtime.router.closed = true;
        host.events.close();
        return host;
    }

    /// Registers a plugin before its first page connects; pages see it from
    /// their next connection. Its endpoint stays valid until detach.
    pub fn use(self: *Host, plugin: Plugin) !void {
        if (self.state == .detached) return error.Closed;
        if (!validName(plugin.name)) return error.InvalidName;
        for (self.plugins[0..self.plugin_count]) |existing| if (std.mem.eql(u8, existing.name, plugin.name)) return error.DuplicateName;
        if (self.plugin_count == max_plugins) return error.Full;
        self.plugins[self.plugin_count] = plugin;
        self.sessions[self.plugin_count] = unset;
        self.plugin_count += 1;
    }

    /// Routes one page message. Runtime messages begin exactly as the page
    /// runtime writes them: the hello, or `{"v":1,"session":"<session>"`.
    pub fn receive(self: *Host, bytes: []const u8) Received {
        if (std.mem.eql(u8, bytes, hello)) {
            if (self.state != .detached) self.connect();
            return .handled;
        }
        const prefix = "{\"v\":1,\"session\":\"";
        if (!std.mem.startsWith(u8, bytes, prefix) or bytes.len < prefix.len + 33 or bytes[prefix.len + 32] != '"') return .foreign;
        const session = ipc.Session.init(bytes[prefix.len..][0..32]) catch return .foreign;
        if (self.state != .connected) return .handled;
        if (session.eql(self.runtime.router.session)) {
            self.receiveRuntime(bytes[prefix.len + 33 ..], bytes);
        } else for (self.sessions[0..self.plugin_count], self.plugins[0..self.plugin_count]) |plugin_session, plugin| {
            if (session.eql(plugin_session)) {
                plugin.endpoint.vtable.receive(plugin.endpoint.context, self, bytes);
                break;
            }
        }
        return .handled;
    }

    /// The document went away (navigation, reload, process failure). Work is
    /// canceled and nothing is sent until the next document says hello.
    pub fn pageChanged(self: *Host) void {
        if (self.state != .connected) return;
        self.disconnect();
        self.state = .waiting;
    }

    /// Ends the Host. Plugins are closed once; the Host never sends again.
    pub fn detach(self: *Host) void {
        if (self.state == .connected) self.disconnect();
        self.state = .detached;
    }

    pub fn connected(self: *const Host) bool {
        return self.state == .connected;
    }

    /// Sends one message to the current document. Used by plugin endpoints.
    pub fn send(self: *Host, bytes: []const u8) !void {
        if (self.state != .connected) return error.NotConnected;
        try self.transport.send(self.transport.context, bytes);
    }

    /// The language the app shows. Connected pages receive a locale event;
    /// later documents start with it.
    pub fn setLocale(self: *Host, locale: i18n.Locale) !bool {
        self.locale = locale;
        return self.emit("locale", .{ .locale = self.locale.tag(), .dir = direction(locale) });
    }

    pub fn setPreferences(self: *Host, preferences: Preferences) !bool {
        self.preferences = preferences;
        var accent: [7]u8 = undefined;
        return self.emit("preferences", preferences.wire(&accent));
    }

    /// Paths are borrowed for the call. Returns false when no page listens.
    pub fn fileDrop(self: *Host, paths: []const []const u8, x: f64, y: f64) !bool {
        return self.emit("fileDrop", .{ .paths = paths, .x = x, .y = y });
    }

    pub fn documentState(self: *Host, state: service.DocumentState) !bool {
        return self.emit("documentState", state);
    }

    pub fn documentReload(self: *Host) !bool {
        return self.emit("documentReload", {});
    }

    fn emit(self: *Host, comptime event: []const u8, value: @field(service.Service.events, event).Payload) !bool {
        if (self.state != .connected) return false;
        const token = self.events.token(event);
        if (token.subscription == 0) return false;
        const bytes = try self.events.emit(event, self.allocator, token, value);
        defer self.allocator.free(bytes);
        self.send(bytes) catch |err| {
            self.transportFailed(err);
            return err;
        };
        return true;
    }

    fn fresh(self: *Host) ipc.Session {
        while (true) {
            var bytes: [16]u8 = undefined;
            self.random.bytes(&bytes);
            const session = ipc.Session.init(&std.fmt.bytesToHex(bytes, .lower)) catch unreachable;
            if (session.eql(unset) or session.eql(self.runtime.router.session)) continue;
            for (self.sessions[0..self.plugin_count]) |other| {
                if (session.eql(other)) break;
            } else return session;
        }
    }

    fn connect(self: *Host) void {
        if (self.state == .connected) self.disconnect();
        var canceled: [limits.max_pending]ipc.Token = undefined;
        const session = self.fresh();
        _ = self.runtime.router.reset(session, &canceled) catch unreachable;
        self.events.reset(session) catch unreachable;
        for (self.sessions[0..self.plugin_count]) |*plugin_session| plugin_session.* = unset;
        for (self.sessions[0..self.plugin_count]) |*plugin_session| plugin_session.* = self.fresh();
        self.state = .connected;
        for (self.plugins[0..self.plugin_count], self.sessions[0..self.plugin_count]) |plugin, plugin_session| {
            plugin.endpoint.vtable.open(plugin.endpoint.context, self, plugin_session);
        }
        const bytes = self.configuration() catch |err| {
            self.last_error = err;
            self.pageChanged();
            return;
        };
        defer self.allocator.free(bytes);
        self.send(bytes) catch |err| self.transportFailed(err);
    }

    fn disconnect(self: *Host) void {
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.runtime.router.close(&canceled) catch unreachable;
        self.events.close();
        self.close_requested = false;
        // Plugins see close before the session ids are forgotten.
        self.state = .waiting;
        for (self.plugins[0..self.plugin_count]) |plugin| plugin.endpoint.vtable.close(plugin.endpoint.context, self);
        for (self.sessions[0..self.plugin_count]) |*plugin_session| plugin_session.* = unset;
    }

    fn transportFailed(self: *Host, err: anyerror) void {
        // A dropped packet cannot be skipped: end the connection instead.
        self.last_error = err;
        self.pageChanged();
    }

    /// The runtime's view of this document, sent in answer to hello.
    fn configuration(self: *Host) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const w = &output.writer;
        var accent: [7]u8 = undefined;
        writeConfiguration(self, w, &accent) catch return error.OutOfMemory;
        if (output.written().len > limits.max_message_bytes) return error.MessageTooLarge;
        return output.toOwnedSlice();
    }

    fn writeConfiguration(self: *Host, w: *std.Io.Writer, accent: *[7]u8) !void {
        var json: std.json.Stringify = .{ .writer = w };
        try json.beginObject();
        try json.objectField("ziggurat");
        try json.write("runtime");
        try json.objectField("v");
        try json.write(handshake_version);
        try json.objectField("platform");
        try json.write(@tagName(platform));
        try json.objectField("windowId");
        try json.write(self.window_id);
        try json.objectField("version");
        try json.write(self.version);
        try json.objectField("locale");
        try json.write(self.locale.tag());
        try json.objectField("dir");
        try json.write(@tagName(direction(self.locale)));
        try json.objectField("preferences");
        try json.write(self.preferences.wire(accent));
        try json.objectField("services");
        try json.beginObject();
        try json.objectField(service.name);
        try json.write(&self.runtime.router.session.bytes);
        var name: [max_name_bytes + 7]u8 = undefined;
        for (self.plugins[0..self.plugin_count], self.sessions[0..self.plugin_count]) |plugin, session| {
            try json.objectField(std.fmt.bufPrint(&name, "plugin:{s}", .{plugin.name}) catch unreachable);
            try json.write(&session.bytes);
        }
        try json.endObject();
        try json.endObject();
    }

    fn receiveRuntime(self: *Host, rest: []const u8, bytes: []const u8) void {
        if (std.mem.startsWith(u8, rest, ",\"kind\":\"subscribe\"") or std.mem.startsWith(u8, rest, ",\"kind\":\"unsubscribe\"")) {
            _ = self.events.receive(self.allocator, bytes) catch |err| {
                // Invalid subscription controls end the document connection.
                self.last_error = err;
                if (err != error.OutOfMemory) self.pageChanged();
            };
            return;
        }
        var action = self.runtime.dispatch(self.allocator, &self.implementation, self, bytes) catch |err| {
            self.last_error = err;
            return;
        };
        switch (action) {
            .reply => |*pending| {
                defer pending.deinit();
                const packet = pending.encode(&self.runtime.router, self.allocator) catch |err| {
                    self.last_error = err;
                    return;
                };
                defer self.allocator.free(packet);
                self.send(packet) catch |err| return self.transportFailed(err);
                if (self.close_requested) {
                    self.close_requested = false;
                    self.controls.vtable.close(self.controls.context) catch |err| {
                        self.last_error = err;
                    };
                }
            },
            .rejected => |rejected| {
                const packet = ipc.protocol.reject(self.allocator, rejected.token, rejected.code, limits.max_message_bytes) catch |err| {
                    self.last_error = err;
                    return;
                };
                defer self.allocator.free(packet);
                self.send(packet) catch |err| self.transportFailed(err);
            },
            // Every runtime method replies synchronously; nothing is taken,
            // streamed or left to cancel.
            .taken, .cancel, .ack => {},
        }
    }
};

pub fn direction(locale: i18n.Locale) service.Direction {
    return switch (locale.direction()) {
        .ltr => .ltr,
        .rtl => .rtl,
    };
}
