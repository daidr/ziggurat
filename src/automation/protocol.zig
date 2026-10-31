//! The automation protocol: one JSON object per line from the client, one
//! answer per line from the app, in order. Each request has an `id`, which
//! the answer repeats, a `method` and its `params`; an answer has a
//! `result`, or an `error` with a `code` to test and a `message` to read.
//! This file parses requests, checks their params, and writes answers;
//! what a request does in the app is the `Driver`'s.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const names = @import("names.zig");

/// The longest request a line may hold, as a script to evaluate.
pub const max_line = 16 << 20;

/// What clients test an error by.
pub const Code = enum {
    /// The line is not a JSON object; its answer's `id` is null.
    parse_error,
    /// No method, params the method does not take, or values it cannot use.
    invalid_request,
    unknown_method,
    /// No window has the ID, or the app has none.
    no_window,
    /// No element of the window's last frame has the ID or the key.
    no_element,
    /// The window cannot do it, as reading the elements of a page.
    unsupported,
    /// `idle` gave up after its `timeout`.
    timeout,
    /// The app could not do it, as a script that threw.
    failed,
};

/// Why a request failed. The message is the request's to own.
pub const Failure = struct { code: Code = .failed, message: []const u8 = "" };

/// A driver fails with `Failed` after filling the request's `Failure`, and
/// with `Quit` once the app has quit, which closes the connection.
pub const Error = error{ Failed, Quit, OutOfMemory };

/// Sets `failure` and returns `error.Failed`, formatting the message in
/// `arena`.
pub fn fail(failure: *Failure, arena: std.mem.Allocator, code: Code, comptime format: []const u8, args: anytype) Error {
    failure.* = .{ .code = code, .message = std.fmt.allocPrint(arena, format, args) catch "out of memory" };
    return error.Failed;
}

pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };

/// A window, as `windows` lists it.
pub const WindowInfo = struct {
    id: u64,
    title: []const u8,
    /// `content` for a window of native UI, `page` for a web page.
    kind: []const u8,
    /// A page's.
    url: ?[]const u8 = null,
    bounds: Rect,
    contentBounds: Rect,
    focused: bool,
    visible: bool,
};

/// An element ID or key: 64-bit, so it goes as a string of digits, which
/// JavaScript's numbers would round.
pub const Digits = struct {
    value: u64,
    pub fn jsonStringify(self: Digits, writer: anytype) !void {
        try writer.print("\"{d}\"", .{self.value});
    }
};

/// An element as assistive technology reads it.
pub const Node = struct {
    id: Digits,
    /// Left out for the elements at the top.
    parent: ?Digits = null,
    role: []const u8,
    /// The key the app gave the element with `Style.key`.
    key: ?Digits = null,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    description: ?[]const u8 = null,
    bounds: Rect,
    states: ?[]const []const u8 = null,
    actions: ?[]const []const u8 = null,
    /// Those of a slider, a progress bar, a meter or a stepper.
    min: ?f64 = null,
    max: ?f64 = null,
    now: ?f64 = null,
    step: ?f64 = null,
    level: ?u32 = null,
    posInSet: ?u32 = null,
    setSize: ?u32 = null,
    /// The node of an embedded web view, whose page the tree leaves out.
    webView: ?bool = null,
};

pub const Tree = struct {
    window: u64,
    /// The element with the keyboard focus.
    focus: ?Digits = null,
    nodes: []const Node,
    announcements: ?[]const []const u8 = null,
};

pub const Action = enum { press, focus, increment, decrement, setValue, insertText, selectText, scrollIntoView, expand, collapse };

pub const Act = struct {
    id: u64,
    action: Action,
    /// setValue's and insertText's.
    text: []const u8 = "",
    /// selectText's, in characters.
    from: u64 = 0,
    to: u64 = 0,
};

pub const Pointer = struct {
    x: f32,
    y: f32,
    button: z.PointerButton = .primary,
    modifiers: z.KeyModifiers = .{},
};

pub const InputEvent = union(enum) {
    pointer_move: Pointer,
    pointer_down: Pointer,
    pointer_up: Pointer,
    wheel: struct { pointer: Pointer, dx: f32, dy: f32 },
    key_down: z.KeyInput,
    key_up: z.KeyInput,
    text: []const u8,
};

pub const Capture = struct {
    /// PNG bytes; the answer holds them in base64.
    png: []const u8,
    width: u32,
    height: u32,
};

/// What requests do in the app. Window 0 is the default window: the
/// focused one, else the first. Called from the threads of connections;
/// a driver hops to the main thread for what it touches. Results are
/// allocated in `arena`, which lives until the answer is written.
pub const Driver = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        windows: *const fn (*anyopaque, std.mem.Allocator, *Failure) Error![]const WindowInfo,
        tree: *const fn (*anyopaque, std.mem.Allocator, u64, *Failure) Error!Tree,
        act: *const fn (*anyopaque, std.mem.Allocator, u64, Act, *Failure) Error!void,
        input: *const fn (*anyopaque, std.mem.Allocator, u64, []const InputEvent, *Failure) Error!void,
        menu: *const fn (*anyopaque, std.mem.Allocator, u64, []const []const u8, *Failure) Error!void,
        capture: *const fn (*anyopaque, std.mem.Allocator, u64, *Failure) Error!Capture,
        /// The script's value as JSON.
        eval: *const fn (*anyopaque, std.mem.Allocator, u64, []const u8, *Failure) Error![]const u8,
        /// Waits at most `timeout` milliseconds when it is not 0.
        idle: *const fn (*anyopaque, std.mem.Allocator, u64, u64, *Failure) Error!void,
    };
};

/// Answers one request line on `out`, followed by a newline. Returns
/// `error.Quit` once the app has quit, when nothing is written.
pub fn handle(driver: Driver, arena: std.mem.Allocator, line: []const u8, out: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    var failure: Failure = .{};
    var id: []const u8 = "null";
    const result = call(driver, arena, line, &id, &failure);
    // The app ends; the client sees the connection close instead.
    if (result == error.Quit) return error.Quit;
    try out.writeAll("{\"id\":");
    try out.writeAll(id);
    if (result) |value| {
        try out.writeAll(",\"result\":");
        try out.writeAll(value);
    } else |err| switch (err) {
        error.Quit => unreachable,
        error.OutOfMemory => {
            try out.writeAll(",\"error\":{\"code\":\"failed\",\"message\":\"out of memory\"}");
        },
        error.Failed => {
            try out.writeAll(",\"error\":{\"code\":");
            try std.json.Stringify.encodeJsonString(@tagName(failure.code), .{}, out);
            try out.writeAll(",\"message\":");
            try std.json.Stringify.encodeJsonString(failure.message, .{}, out);
            try out.writeAll("}");
        },
    }
    try out.writeAll("}\n");
}

/// An answer for a line longer than `max_line`.
pub fn writeTooLong(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{{\"id\":null,\"error\":{{\"code\":\"parse_error\",\"message\":\"a request is longer than {d} bytes\"}}}}\n", .{max_line});
}

const Value = std.json.Value;

/// Performs a request; returns its result as JSON.
fn call(driver: Driver, arena: std.mem.Allocator, line: []const u8, id: *[]const u8, failure: *Failure) Error![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(failure, arena, .parse_error, "the line is not JSON: {s}", .{@errorName(err)}),
    };
    if (parsed != .object) return fail(failure, arena, .parse_error, "a request is a JSON object", .{});
    const request = parsed.object;
    if (request.get("id")) |value| id.* = try stringify(arena, value);
    var top = request.iterator();
    while (top.next()) |entry| {
        const known = [_][]const u8{ "id", "method", "params" };
        for (known) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return fail(failure, arena, .invalid_request, "the request has no field \"{s}\"", .{entry.key_ptr.*});
    }
    const method_value = request.get("method") orelse return fail(failure, arena, .invalid_request, "the request has no method", .{});
    if (method_value != .string) return fail(failure, arena, .invalid_request, "method is a string", .{});
    const method = method_value.string;
    if (method.len == 0) return fail(failure, arena, .invalid_request, "the request has no method", .{});
    const params: Params = .{ .method = method, .value = request.get("params"), .arena = arena, .failure = failure };

    if (std.mem.eql(u8, method, "windows")) {
        try params.only(&.{});
        const list = try driver.vtable.windows(driver.context, arena, failure);
        return stringify(arena, .{ .windows = list });
    }
    if (std.mem.eql(u8, method, "tree")) {
        try params.only(&.{"window"});
        const tree = try driver.vtable.tree(driver.context, arena, try params.window(), failure);
        return stringify(arena, tree);
    }
    if (std.mem.eql(u8, method, "act")) {
        try params.only(&.{ "window", "id", "key", "action", "text", "from", "to" });
        const window = try params.window();
        const action_name = try params.string("action") orelse return fail(failure, arena, .invalid_request, "act needs an action", .{});
        const action = std.meta.stringToEnum(Action, action_name) orelse return fail(failure, arena, .invalid_request, "no action \"{s}\"", .{action_name});
        const by_id = try params.digits("id");
        const by_key = params.field("key");
        if (by_id == null and by_key == null) return fail(failure, arena, .invalid_request, "act needs the id or the key of an element", .{});
        if (by_id != null and by_key != null) return fail(failure, arena, .invalid_request, "act takes an id or a key, not both", .{});
        var target = by_id orelse 0;
        if (by_key) |value| {
            const want = keyOf(value) orelse return fail(failure, arena, .invalid_request, "a key is a string or a whole number", .{});
            const tree = try driver.vtable.tree(driver.context, arena, window, failure);
            var count: usize = 0;
            for (tree.nodes) |node| if (node.key) |key| if (key.value == want) {
                target = node.id.value;
                count += 1;
            };
            const shown = try stringify(arena, value);
            if (count == 0) return fail(failure, arena, .no_element, "no element has the key {s}", .{shown});
            if (count > 1) return fail(failure, arena, .invalid_request, "{d} elements have the key {s}: act on one by its id", .{ count, shown });
        }
        const text = try params.string("text") orelse "";
        const from = try params.whole("from") orelse 0;
        const to = try params.whole("to") orelse 0;
        try driver.vtable.act(driver.context, arena, window, .{ .id = target, .action = action, .text = text, .from = from, .to = to }, failure);
        return "{}";
    }
    if (std.mem.eql(u8, method, "input")) {
        try params.only(&.{ "window", "events" });
        const window = try params.window();
        const list = params.field("events") orelse return fail(failure, arena, .invalid_request, "input needs its events", .{});
        if (list != .array) return fail(failure, arena, .invalid_request, "events is an array", .{});
        var events: std.ArrayList(InputEvent) = .empty;
        for (list.array.items, 0..) |item, index| try names.inputEvents(arena, item, index, &events, failure);
        try driver.vtable.input(driver.context, arena, window, events.items, failure);
        return "{}";
    }
    if (std.mem.eql(u8, method, "menu")) {
        try params.only(&.{ "window", "path" });
        const window = try params.window();
        const value = params.field("path") orelse return fail(failure, arena, .invalid_request, "menu needs the path of the item, as [\"File\", \"New\"]", .{});
        if (value != .array or value.array.items.len == 0) return fail(failure, arena, .invalid_request, "menu needs the path of the item, as [\"File\", \"New\"]", .{});
        const path = try arena.alloc([]const u8, value.array.items.len);
        for (value.array.items, path) |item, *label| {
            if (item != .string) return fail(failure, arena, .invalid_request, "the path of a menu item is a list of labels", .{});
            label.* = item.string;
        }
        try driver.vtable.menu(driver.context, arena, window, path, failure);
        return "{}";
    }
    if (std.mem.eql(u8, method, "capture")) {
        try params.only(&.{"window"});
        const image = try driver.vtable.capture(driver.context, arena, try params.window(), failure);
        const encoder = std.base64.standard.Encoder;
        const encoded = try arena.alloc(u8, encoder.calcSize(image.png.len));
        _ = encoder.encode(encoded, image.png);
        return stringify(arena, .{ .png = encoded, .width = image.width, .height = image.height });
    }
    if (std.mem.eql(u8, method, "eval")) {
        try params.only(&.{ "window", "script" });
        const window = try params.window();
        const script = try params.string("script") orelse return fail(failure, arena, .invalid_request, "eval needs a script", .{});
        const value = try driver.vtable.eval(driver.context, arena, window, script, failure);
        return std.fmt.allocPrint(arena, "{{\"value\":{s}}}", .{value});
    }
    if (std.mem.eql(u8, method, "idle")) {
        try params.only(&.{ "window", "timeout" });
        const window = try params.window();
        const timeout = params.field("timeout");
        if (timeout) |value| if (value == .integer and value.integer < 0) return fail(failure, arena, .invalid_request, "timeout is negative", .{});
        try driver.vtable.idle(driver.context, arena, window, try params.whole("timeout") orelse 0, failure);
        return "{}";
    }
    return fail(failure, arena, .unknown_method, "no method \"{s}\"", .{method});
}

fn stringify(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

/// The key a request names: a whole number, or a string of digits, is the
/// key's value as `tree` lists it; other text is hashed as `view.key` does.
pub fn keyOf(value: Value) ?u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        .string => |text| std.fmt.parseInt(u64, text, 10) catch view.key(text),
        else => null,
    };
}

/// The params of a request, checked as they are read.
const Params = struct {
    method: []const u8,
    value: ?Value,
    arena: std.mem.Allocator,
    failure: *Failure,

    fn object(self: Params) ?std.json.ObjectMap {
        const value = self.value orelse return null;
        return if (value == .object) value.object else null;
    }
    /// Refuses params that are no object, or that have a field the
    /// method does not take.
    fn only(self: Params, fields: []const []const u8) Error!void {
        const value = self.value orelse return;
        if (value == .null) return;
        if (value != .object) return fail(self.failure, self.arena, .invalid_request, "params of {s} is an object", .{self.method});
        var it = value.object.iterator();
        while (it.next()) |entry| {
            for (fields) |name| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
            } else return fail(self.failure, self.arena, .invalid_request, "params of {s}: unknown field \"{s}\"", .{ self.method, entry.key_ptr.* });
        }
    }
    fn field(self: Params, name: []const u8) ?Value {
        const map = self.object() orelse return null;
        const value = map.get(name) orelse return null;
        return if (value == .null) null else value;
    }
    fn string(self: Params, name: []const u8) Error!?[]const u8 {
        const value = self.field(name) orelse return null;
        if (value != .string) return fail(self.failure, self.arena, .invalid_request, "params of {s}: {s} is a string", .{ self.method, name });
        return value.string;
    }
    fn whole(self: Params, name: []const u8) Error!?u64 {
        const value = self.field(name) orelse return null;
        if (value != .integer or value.integer < 0) return fail(self.failure, self.arena, .invalid_request, "params of {s}: {s} is a whole number", .{ self.method, name });
        return @intCast(value.integer);
    }
    /// A 64-bit ID, given as a string of digits or as a number.
    fn digits(self: Params, name: []const u8) Error!?u64 {
        const value = self.field(name) orelse return null;
        return switch (value) {
            .integer => |n| if (n >= 0) @intCast(n) else fail(self.failure, self.arena, .invalid_request, "params of {s}: {s} is a string of digits", .{ self.method, name }),
            .string, .number_string => |text| std.fmt.parseInt(u64, text, 10) catch fail(self.failure, self.arena, .invalid_request, "params of {s}: {s} is a string of digits, not \"{s}\"", .{ self.method, name, text }),
            else => fail(self.failure, self.arena, .invalid_request, "params of {s}: {s} is a string of digits", .{ self.method, name }),
        };
    }
    fn window(self: Params) Error!u64 {
        return try self.whole("window") orelse 0;
    }
};
