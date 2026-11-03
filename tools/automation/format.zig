//! How the command writes elements, windows and diffs: a line each, short
//! enough for an agent to read many.
const std = @import("std");
const model = @import("model.zig");
const Seen = @import("session.zig").Seen;

const Node = model.Node;
const Writer = std.Io.Writer;

/// How many characters of a label or a value a line shows, unless full.
pub const max_text = 120;

/// Describes an element on a line, without its ref: its role, its label,
/// value and key, and its states, leaving out what it lacks. `full` adds
/// what agents seldom need: placeholders under a label, descriptions,
/// ranges, selections, levels, positions in sets, actions, bounds and the
/// element's ID, and writes long text whole.
pub fn line(w: *Writer, n: *const Node, focus: ?[]const u8, full: bool) Writer.Error!void {
    try w.print("[{s}]", .{n.role});
    const label = Node.text(n.label);
    const value = Node.text(n.value);
    const placeholder = Node.text(n.placeholder);
    if (label.len != 0) {
        try w.writeByte(' ');
        try quote(w, label, full);
    }
    if (value.len != 0) {
        try w.writeAll(" value=");
        try quote(w, value, full);
    } else if (n.now) |now| {
        try w.writeAll(" value=");
        try number(w, now);
    }
    if (placeholder.len != 0 and (full or label.len == 0)) {
        try w.writeAll(" placeholder=");
        try quote(w, placeholder, full);
    }
    if (n.key) |key| try w.print(" key={s}", .{key});
    if (n.states) |states| for (states) |state| {
        // Every control can take the focus: saying so is noise.
        if (!std.mem.eql(u8, state, "focusable")) try w.print(" {s}", .{state});
    };
    if (focus) |id| if (std.mem.eql(u8, id, n.id)) try w.writeAll(" focused");
    if (n.webView orelse false) try w.writeAll(" webview");
    if (!full) return;
    const description = Node.text(n.description);
    if (description.len != 0) {
        try w.writeAll(" description=");
        try quote(w, description, true);
    }
    if (n.min != null and n.max != null) {
        try w.writeAll(" range=");
        try number(w, n.min.?);
        try w.writeAll("..");
        try number(w, n.max.?);
    }
    if (n.step) |step| if (step != 0) {
        try w.writeAll(" step=");
        try number(w, step);
    };
    if (n.selection) |selection| try w.print(" selection={d},{d}", .{ selection[0], selection[1] });
    if (n.level) |level| if (level != 0) try w.print(" level={d}", .{level});
    if (n.setSize) |size| if (size != 0) try w.print(" item={d}/{d}", .{ n.posInSet orelse 0, size });
    if (n.actions) |actions| if (actions.len != 0) {
        try w.writeAll(" actions=");
        for (actions, 0..) |action, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(action);
        }
    };
    const b = n.bounds;
    try w.writeAll(" bounds=");
    try number(w, b.x);
    try w.writeByte(',');
    try number(w, b.y);
    try w.writeByte(',');
    try number(w, b.width);
    try w.writeByte('x');
    try number(w, b.height);
    try w.print(" id={s}", .{n.id});
}

/// `line` into memory.
pub fn lineAlloc(arena: std.mem.Allocator, n: *const Node, focus: ?[]const u8, full: bool) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    line(&out.writer, n, focus, full) catch return error.OutOfMemory;
    return out.written();
}

/// Writes `s` in double quotes, escaping quotes, backslashes and control
/// characters, cut to `max_text` characters unless `full`.
pub fn quote(w: *Writer, s: []const u8, full: bool) Writer.Error!void {
    var end = s.len;
    var more: usize = 0;
    if (!full) {
        var count: usize = 0;
        var index: usize = 0;
        while (index < s.len) {
            const size = std.unicode.utf8ByteSequenceLength(s[index]) catch 1;
            if (count == max_text) end = index;
            count += 1;
            index += @min(size, s.len - index);
        }
        if (count > max_text) more = count - max_text else end = s.len;
    }
    try w.writeByte('"');
    var index: usize = 0;
    const text = s[0..end];
    while (index < text.len) {
        const c = text[index];
        const size = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (size > 1 and index + size <= text.len and std.unicode.utf8ValidateSlice(text[index .. index + size])) {
            try w.writeAll(text[index .. index + size]);
            index += size;
            continue;
        }
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20 or c >= 0x7f) try w.print("\\x{x:0>2}", .{c}) else try w.writeByte(c),
        }
        index += 1;
    }
    if (more != 0) {
        try w.writeAll("…\"");
        try w.print(" ({d} more)", .{more});
    } else try w.writeByte('"');
}

/// Writes a number as briefly as it reads: 1, 0.25, -120.
pub fn number(w: *Writer, value: f64) Writer.Error!void {
    if (value == @trunc(value) and @abs(value) < 1e15) return w.print("{d}", .{@as(i64, @intFromFloat(value))});
    try w.print("{d}", .{value});
}

/// The roles `snapshot -i` keeps even when they have no action now, as a
/// disabled button.
const controls = [_][]const u8{
    "button",     "link",     "checkBox",     "radio",     "switch",       "slider",   "textField",        "popUpButton",   "tab",
    "menuButton", "toggleButton", "comboBox", "disclosure", "stepper",     "colorWell", "menuItem",        "menuItemCheckBox", "menuItemRadio",
    "treeItem",
};

/// Whether `snapshot -i` shows `n`: controls, web views, and elements with
/// actions other than scrolling into view.
pub fn interactive(n: *const Node) bool {
    for (controls) |role| if (std.mem.eql(u8, role, n.role)) return true;
    if (n.webView orelse false) return true;
    if (n.actions) |actions| for (actions) |action| {
        if (!std.mem.eql(u8, action, "scrollIntoView")) return true;
    };
    return false;
}

/// Writes a window's elements, a line each, indented under the elements
/// shown around them.
pub fn snapshot(arena: std.mem.Allocator, w: *Writer, seen: *const Seen, announcements: []const []const u8, interactive_only: bool, full: bool) !void {
    // The depth of each element's children.
    var inner: std.StringHashMapUnmanaged(usize) = .empty;
    var shown: usize = 0;
    for (seen.nodes) |*n| {
        const depth = if (n.parent) |parent| inner.get(parent) orelse 0 else 0;
        const show = !interactive_only or interactive(n);
        try inner.put(arena, n.id, if (show) depth + 1 else depth);
        if (!show) continue;
        shown += 1;
        try w.splatByteAll(' ', depth * 2);
        try w.print("@e{d} ", .{seen.refOf(n.id)});
        try line(w, n, seen.focus, full);
        try w.writeByte('\n');
    }
    if (shown == 0) {
        if (interactive_only and seen.nodes.len != 0) try w.writeAll("(no interactive elements: run snapshot without -i)\n") else try w.writeAll("(no elements)\n");
    }
    try writeAnnouncements(w, announcements);
}

pub fn writeAnnouncements(w: *Writer, announcements: []const []const u8) Writer.Error!void {
    for (announcements) |text| {
        try w.writeAll("announced ");
        try quote(w, text, false);
        try w.writeByte('\n');
    }
}

/// Describes a window on a line.
pub fn window(w: *Writer, info: model.Window, selected: bool) Writer.Error!void {
    try w.print("w{d} [{s}] ", .{ info.id, info.kind });
    try quote(w, info.title, false);
    if (info.url) |url| if (url.len != 0) try w.print(" url={s}", .{url});
    if (info.focused) try w.writeAll(" focused");
    if (!info.visible) try w.writeAll(" hidden");
    if (selected) try w.writeAll(" selected");
}

/// A line of a diff: '+' an element added or as it is now, '-' one gone
/// or as it was, '=' one unchanged around them.
pub const DiffLine = struct {
    op: u8,
    ref: u64,
    text: []const u8,

    pub fn write(self: DiffLine, w: *Writer) Writer.Error!void {
        try w.print("{c} @e{d} {s}\n", .{ self.op, self.ref, self.text });
    }
};

/// Compares what a window showed before with what it shows now, in the
/// order of now, and keeps `context` unchanged elements around each
/// change. An element whose line changed shows twice, as it was ('-') and
/// as it is ('+'), with its ref; one gone shows with its ref, now stale.
pub fn diff(arena: std.mem.Allocator, before_seen: ?Seen, now: *const Seen, context: usize) ![]DiffLine {
    const before = before_seen orelse Seen{};
    var at: std.StringHashMapUnmanaged(usize) = .empty;
    for (before.nodes, 0..) |n, i| {
        const entry = try at.getOrPut(arena, n.id);
        if (!entry.found_existing) entry.value_ptr.* = i;
    }
    var stays: std.StringHashMapUnmanaged(void) = .empty;
    for (now.nodes) |n| try stays.put(arena, n.id, {});

    var all: std.ArrayList(DiffLine) = .empty;
    var next: usize = 0;
    for (now.nodes) |*n| {
        const ref = now.refOf(n.id);
        const text = try lineAlloc(arena, n, now.focus, false);
        const p = at.get(n.id) orelse {
            try all.append(arena, .{ .op = '+', .ref = ref, .text = text });
            continue;
        };
        if (p >= next) {
            try gone(arena, &all, &before, &stays, &next, p);
            next = p + 1;
        }
        const was = try lineAlloc(arena, &before.nodes[p], before.focus, false);
        if (!std.mem.eql(u8, was, text)) {
            try all.append(arena, .{ .op = '-', .ref = ref, .text = was });
            try all.append(arena, .{ .op = '+', .ref = ref, .text = text });
        } else try all.append(arena, .{ .op = '=', .ref = ref, .text = text });
    }
    try gone(arena, &all, &before, &stays, &next, before.nodes.len);

    var out: std.ArrayList(DiffLine) = .empty;
    for (all.items, 0..) |d, i| {
        var keep = d.op != '=';
        var j = i -| context;
        while (!keep and j <= @min(i + context, all.items.len - 1)) : (j += 1) keep = all.items[j].op != '=';
        if (keep) try out.append(arena, d);
    }
    return out.items;
}

fn gone(arena: std.mem.Allocator, all: *std.ArrayList(DiffLine), before: *const Seen, stays: *const std.StringHashMapUnmanaged(void), next: *usize, up_to: usize) !void {
    while (next.* < up_to) : (next.* += 1) {
        const n = &before.nodes[next.*];
        if (!stays.contains(n.id)) try all.append(arena, .{ .op = '-', .ref = before.refOf(n.id), .text = try lineAlloc(arena, n, before.focus, false) });
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectLine(n: Node, full: bool, want: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(want, try lineAlloc(arena_state.allocator(), &n, "3", full));
}

test "a line has the role, label, value, key and states, and what is empty is left out" {
    try expectLine(.{ .id = "1", .role = "text", .label = "Count: 0" }, false, "[text] \"Count: 0\"");
    try expectLine(.{ .id = "2", .role = "button", .label = "Add", .key = "17487022006909920864", .states = &.{ "focusable", "disabled" }, .actions = &.{"press"} }, false, "[button] \"Add\" key=17487022006909920864 disabled");
    // The focused element, a value, and a placeholder only under no label.
    try expectLine(.{ .id = "3", .role = "textField", .label = "Name", .value = "Ada", .placeholder = "Your name" }, false, "[textField] \"Name\" value=\"Ada\" focused");
    try expectLine(.{ .id = "4", .role = "textField", .placeholder = "Search" }, false, "[textField] placeholder=\"Search\"");
    // A slider's value, when it has no text for it.
    const slider: Node = .{ .id = "6", .role = "slider", .label = "Volume", .min = 0, .max = 1, .now = 0.25, .step = 0.05 };
    try expectLine(slider, false, "[slider] \"Volume\" value=0.25");
    try expectLine(slider, true, "[slider] \"Volume\" value=0.25 range=0..1 step=0.05 bounds=0,0,0x0 id=6");
    try expectLine(.{ .id = "7", .role = "group", .webView = true }, false, "[group] webview");
    try expectLine(.{ .id = "18446744073709551615", .role = "textField", .label = "Name", .value = "Ada", .placeholder = "Your name", .description = "Who", .selection = .{ 1, 3 }, .actions = &.{ "focus", "setValue" }, .bounds = .{ .x = 20, .y = 90.5, .width = 360, .height = 32 } }, true, "[textField] \"Name\" value=\"Ada\" placeholder=\"Your name\" description=\"Who\" selection=1,3 actions=focus,setValue bounds=20,90.5,360x32 id=18446744073709551615");
    try expectLine(.{ .id = "8", .role = "treeItem", .label = "src", .level = 2, .posInSet = 1, .setSize = 3, .states = &.{ "expandable", "expanded" } }, true, "[treeItem] \"src\" expandable expanded level=2 item=1/3 bounds=0,0,0x0 id=8");
}

test "long text is cut, and lines stay lines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var built: std.ArrayList(u8) = .empty;
    for (0..max_text) |_| try built.appendSlice(arena, "é");
    const kept = try arena.dupe(u8, built.items);
    for (0..30) |_| try built.appendSlice(arena, "é");
    const long = built.items;
    var n: Node = .{ .id = "1", .role = "textField", .value = long };
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "[textField] value=\"{s}…\" (30 more)", .{kept}), try lineAlloc(arena, &n, null, false));
    try testing.expect(std.mem.indexOf(u8, try lineAlloc(arena, &n, null, true), try std.fmt.allocPrint(arena, "value=\"{s}\"", .{long})) != null);
    n.value = "a\nb\"\\";
    try testing.expectEqualStrings("[textField] value=\"a\\nb\\\"\\\\\"", try lineAlloc(arena, &n, null, false));
}

test "a snapshot indents elements under those shown around them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seen: Seen = .{ .focus = "4", .nodes = &.{
        .{ .id = "1", .role = "dialog", .label = "Settings" },
        .{ .id = "2", .parent = "1", .role = "text", .label = "Theme" },
        .{ .id = "3", .parent = "1", .role = "group" },
        .{ .id = "4", .parent = "3", .role = "checkBox", .label = "Dark", .states = &.{ "focusable", "checked" }, .actions = &.{ "press", "focus" } },
        .{ .id = "5", .role = "button", .label = "Close", .actions = &.{"press"} },
    } };
    for ([_][]const u8{ "1", "2", "3", "4", "5" }, 1..) |id, ref| try seen.refs.map.put(arena, id, ref);
    var out: Writer.Allocating = .init(arena);
    try snapshot(arena, &out.writer, &seen, &.{"Saved"}, false, false);
    try testing.expectEqualStrings(
        \\@e1 [dialog] "Settings"
        \\  @e2 [text] "Theme"
        \\  @e3 [group]
        \\    @e4 [checkBox] "Dark" checked focused
        \\@e5 [button] "Close"
        \\announced "Saved"
        \\
    , out.written());
    out.clearRetainingCapacity();
    try snapshot(arena, &out.writer, &seen, &.{}, true, false);
    try testing.expectEqualStrings(
        \\@e4 [checkBox] "Dark" checked focused
        \\@e5 [button] "Close"
        \\
    , out.written());
    out.clearRetainingCapacity();
    const controls_left_out: Seen = .{ .nodes = seen.nodes[0..3], .refs = seen.refs };
    try snapshot(arena, &out.writer, &controls_left_out, &.{}, true, false);
    try testing.expect(std.mem.startsWith(u8, out.written(), "(no interactive elements"));
}

test "a window line names its kind, title, page and state" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try window(&w, .{ .id = 2, .title = "Docs", .kind = "page", .url = "http://localhost:5173/", .visible = false }, true);
    try testing.expectEqualStrings("w2 [page] \"Docs\" url=http://localhost:5173/ hidden selected", w.buffered());
    w = .fixed(&buffer);
    try window(&w, .{ .id = 1, .title = "Counter", .focused = true }, false);
    try testing.expectEqualStrings("w1 [content] \"Counter\" focused", w.buffered());
}

fn texts(arena: std.mem.Allocator, specs: []const []const u8) ![]Node {
    var out: std.ArrayList(Node) = .empty;
    for (specs) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, ':').?;
        try out.append(arena, .{ .id = spec[0..at], .role = "text", .label = spec[at + 1 ..] });
    }
    return out.items;
}

fn diffText(arena: std.mem.Allocator, lines: []const DiffLine) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    for (lines) |l| try l.write(&out.writer);
    return out.written();
}

test "a diff shows what came, went and changed, with the elements around them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Session = @import("session.zig").Session;
    var s: Session = .{};
    _ = try s.observe(arena, .{ .window = 1, .nodes = try texts(arena, &.{ "1:title", "2:a", "3:b", "4:c", "5:d", "6:e", "7:f", "8:g" }) });
    // b changes, e goes, x comes after f; focus moves to g.
    var before = try s.observe(arena, .{ .window = 1, .focus = "8", .nodes = try texts(arena, &.{ "1:title", "2:a", "3:B", "4:c", "5:d", "7:f", "9:x", "8:g" }) });
    try testing.expectEqualStrings(
        \\= @e2 [text] "a"
        \\- @e3 [text] "b"
        \\+ @e3 [text] "B"
        \\= @e4 [text] "c"
        \\= @e5 [text] "d"
        \\- @e6 [text] "e"
        \\= @e7 [text] "f"
        \\+ @e9 [text] "x"
        \\- @e8 [text] "g"
        \\+ @e8 [text] "g" focused
        \\
    , try diffText(arena, try diff(arena, before, s.shown(1).?, 1)));

    // Nothing changed; moves alone change nothing.
    before = try s.observe(arena, .{ .window = 1, .focus = "8", .nodes = try texts(arena, &.{ "1:title", "2:a", "3:B", "4:c", "5:d", "7:f", "9:x", "8:g" }) });
    try testing.expectEqual(@as(usize, 0), (try diff(arena, before, s.shown(1).?, 1)).len);
    before = try s.observe(arena, .{ .window = 1, .focus = "8", .nodes = try texts(arena, &.{ "8:g", "1:title", "2:a", "3:B", "4:c", "5:d", "7:f", "9:x" }) });
    try testing.expectEqual(@as(usize, 0), (try diff(arena, before, s.shown(1).?, 1)).len);
    // A window seen for the first time is all new; one emptied all gone.
    before = try s.observe(arena, .{ .window = 3, .nodes = try texts(arena, &.{"1:new"}) });
    try testing.expectEqualStrings("+ @e10 [text] \"new\"\n", try diffText(arena, try diff(arena, before, s.shown(3).?, 1)));
    before = try s.observe(arena, .{ .window = 3 });
    try testing.expectEqualStrings("- @e10 [text] \"new\"\n", try diffText(arena, try diff(arena, before, s.shown(3).?, 1)));
}
