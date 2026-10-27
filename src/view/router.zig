//! Navigation history for the pages of a window, or of part of one, as a
//! browser keeps it for a tab. The application owns a `Router` over a
//! fixed array of `RouteEntry` it provides; nothing allocates. A location
//! is a path with an optional query, such as "/notes/42?tab=info".
//!
//! `View.route` builds the page shown: it opens a column keyed by the
//! page, so the nodes of different pages never share identity, and returns
//! a `Route` whose `match` tells paths apart by pattern. `Router.push` goes
//! to a page after the one shown and forgets the pages after it,
//! `replace` shows one in its place, and `back`, `forward` and `go` move
//! through the history. When the history is full, the oldest entry goes.
//!
//! Alt+Left and Alt+Right (the other way round right to left), the
//! keyboard's Back and Forward keys and the back and forward buttons of a
//! mouse go back and forward in the router holding the focus, else in
//! the first router built in the window. Backspace does not.
//! `View.backButton` and `View.forwardButton` do the same from a toolbar.
//!
//! Going to another page moves the focus into it when the focus was in
//! the page that left: to the control that had it when the page was last
//! shown, else to its first control. With the focus outside, as in a
//! sidebar choosing the pages, the focus stays and the new page's title
//! is announced instead.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;

/// Longest location, in bytes.
pub const max_location = 256;
/// Longest page title kept for the history, in bytes.
pub const max_title = 96;
/// Most `{name}` wildcards one pattern matches.
pub const max_params = 8;

pub const Error = error{ EmptyHistory, LocationTooLong, InvalidLocation };

/// One page in the history. The application provides the array and never
/// reads or writes entries itself; use the `Router` methods.
pub const RouteEntry = struct {
    location_bytes: [max_location]u8 = undefined,
    location_len: u16 = 0,
    title_bytes: [max_title]u8 = undefined,
    title_len: u8 = 0,
    /// The page shown: entries of the same path share it.
    page: u64 = 0,
    /// The control that had focus in the page when it was last shown.
    focus: ?u64 = null,

    pub fn location(self: *const RouteEntry) []const u8 {
        return self.location_bytes[0..self.location_len];
    }
    /// The page's title as its build last set it, or empty.
    pub fn title(self: *const RouteEntry) []const u8 {
        return self.title_bytes[0..self.title_len];
    }
    pub fn path(self: *const RouteEntry) []const u8 {
        return pathOf(self.location());
    }
};

/// Keep the Router, and its entries, at a stable address from the first
/// build that shows it. Read and change it on the main thread only, as
/// the rest of the application state.
pub const Router = struct {
    entries: []RouteEntry,
    /// Index in `entries` of the oldest entry.
    head: usize = 0,
    len: usize = 0,
    /// The entry shown, counted from the oldest.
    at: usize = 0,
    pages: u64 = 0,
    /// The page the last build showed, and the control in it that had
    /// focus then.
    shown: ?u64 = null,
    focus_in_page: ?u64 = null,
    /// The route of the page being built.
    route: Route = undefined,

    /// A history in `entries` showing `location` first.
    pub fn init(entries: []RouteEntry, first: []const u8) Error!Router {
        if (entries.len == 0) return error.EmptyHistory;
        var self: Router = .{ .entries = entries };
        var buffer: [max_location]u8 = undefined;
        const resolved = try resolve(&buffer, "/", first);
        const entry = &entries[0];
        entry.* = .{};
        self.write(entry, resolved);
        entry.page = self.newPage();
        self.len = 1;
        return self;
    }

    /// Go to `target` after the page shown, forgetting the pages after it:
    /// an absolute path, or one relative to the page shown as a link in a
    /// web page is, such as "edit", "../settings" or "?tab=info". Going to
    /// the location shown does nothing. The same path with another query is
    /// the same page, keeping its node identity.
    pub fn push(self: *Router, target: []const u8) Error!void {
        const current = self.shownEntry();
        var buffer: [max_location]u8 = undefined;
        const resolved = try resolve(&buffer, current.location(), target);
        if (std.mem.eql(u8, resolved, current.location())) return;
        const same = std.mem.eql(u8, pathOf(resolved), current.path());
        const page = if (same) current.page else self.newPage();
        self.len = self.at + 1;
        if (self.len == self.entries.len) {
            // The oldest entry makes room.
            self.head = (self.head + 1) % self.entries.len;
            self.len -= 1;
            self.at -|= 1;
        }
        const entry = self.slot(self.len);
        entry.* = .{ .page = page };
        self.write(entry, resolved);
        self.len += 1;
        self.at = self.len - 1;
    }

    /// Show `target` in place of the page shown, which Back does not
    /// return to. The same path with another query keeps the page and its
    /// title, as a search page following what is typed.
    pub fn replace(self: *Router, target: []const u8) Error!void {
        const current = self.shownEntry();
        var buffer: [max_location]u8 = undefined;
        const resolved = try resolve(&buffer, current.location(), target);
        if (std.mem.eql(u8, resolved, current.location())) return;
        if (!std.mem.eql(u8, pathOf(resolved), current.path())) {
            current.page = self.newPage();
            current.title_len = 0;
            current.focus = null;
        }
        self.write(current, resolved);
    }

    /// Show the page before, if any.
    pub fn back(self: *Router) void {
        self.go(-1);
    }
    /// Show the page after, which `back` left, if any.
    pub fn forward(self: *Router) void {
        self.go(1);
    }
    /// Move `n` pages through the history, back for a negative `n`, as far
    /// as it goes.
    pub fn go(self: *Router, n: isize) void {
        const last: isize = @intCast(self.len - 1);
        const target = std.math.clamp(@as(isize, @intCast(self.at)) + n, 0, last);
        self.at = @intCast(target);
    }
    pub fn canGoBack(self: *const Router) bool {
        return self.at > 0;
    }
    pub fn canGoForward(self: *const Router) bool {
        return self.at + 1 < self.len;
    }

    /// The location shown, with its query.
    pub fn location(self: *const Router) []const u8 {
        return self.entryAt(0).?.location();
    }
    /// The path shown, without its query.
    pub fn path(self: *const Router) []const u8 {
        return pathOf(self.location());
    }
    /// The value of query parameter `name` of the page shown, as written;
    /// null without one.
    pub fn query(self: *const Router, name: []const u8) ?[]const u8 {
        return queryOf(self.location(), name);
    }
    /// The title of the page shown, as its build last set it.
    pub fn title(self: *const Router) []const u8 {
        return self.entryAt(0).?.title();
    }
    /// The entry `offset` pages from the one shown, back for a negative
    /// offset, such as for a menu of pages to go back to; null past the
    /// ends.
    pub fn entryAt(self: *const Router, offset: isize) ?*const RouteEntry {
        const index = @as(isize, @intCast(self.at)) + offset;
        if (index < 0 or index >= self.len) return null;
        return &self.entries[(self.head + @as(usize, @intCast(index))) % self.entries.len];
    }

    fn shownEntry(self: *Router) *RouteEntry {
        return self.slot(self.at);
    }
    fn slot(self: *Router, index: usize) *RouteEntry {
        return &self.entries[(self.head + index) % self.entries.len];
    }
    fn newPage(self: *Router) u64 {
        self.pages += 1;
        return self.pages;
    }
    fn write(_: *Router, entry: *RouteEntry, resolved: []const u8) void {
        @memcpy(entry.location_bytes[0..resolved.len], resolved);
        entry.location_len = @intCast(resolved.len);
    }
    /// Stable action ids for this router's keys and buttons.
    fn actionId(self: *const Router, tag: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0x726f_7574_65);
        hasher.update(std.mem.asBytes(&@intFromPtr(self)));
        hasher.update(tag);
        const value = hasher.final();
        return if (value == 0) 1 else value;
    }
};

pub const Param = struct { name: []const u8, value: []const u8 };

/// The page a `View.route` builds. Its strings live in the pass's text
/// storage, so they stay valid through the build even when it changes the
/// router.
pub const Route = struct {
    router: *Router,
    view: *View,
    /// Index of the page's node.
    node: u32,
    /// The entry and page this route builds, as they were when it opened.
    entry: *RouteEntry,
    page: u64,
    location: []const u8,
    params: [max_params]Param = undefined,
    param_count: usize = 0,

    /// The path of the page, without its query.
    pub fn path(self: *const Route) []const u8 {
        return pathOf(self.location);
    }
    /// Whether the page's path matches `pattern`, whose parts between
    /// slashes are either the same as the path's or wildcards: `{name}`
    /// takes any one part and `{name...}`, at the end, the rest of the
    /// path, which may be empty. A trailing slash makes no difference.
    /// Parts compare as written, without decoding escapes. A match with
    /// `{name...}` makes the page a layout: pages that differ only in the
    /// rest share its node identity. Match before building the page's
    /// content.
    pub fn match(self: *Route, pattern: []const u8) bool {
        var params: [max_params]Param = undefined;
        var count: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var segments = std.mem.tokenizeScalar(u8, self.path(), '/');
        while (parts.next()) |part| {
            const wildcard = part.len >= 2 and part[0] == '{' and part[part.len - 1] == '}';
            if (!wildcard) {
                const segment = segments.next() orelse return false;
                if (!std.mem.eql(u8, segment, part)) return false;
                continue;
            }
            const name = part[1 .. part.len - 1];
            if (std.mem.endsWith(u8, name, "...")) {
                // The rest of the path, from where the segments stopped.
                if (parts.peek() != null) return false;
                const whole = self.path();
                var start = segments.index;
                while (start < whole.len and whole[start] == '/') start += 1;
                var rest = whole[start..];
                while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
                if (count == max_params) return false;
                params[count] = .{ .name = name[0 .. name.len - 3], .value = rest };
                count += 1;
                self.accept(params[0..count]);
                self.layout(whole[0..@min(segments.index, whole.len)]);
                return true;
            }
            const segment = segments.next() orelse return false;
            if (count == max_params) return false;
            params[count] = .{ .name = name, .value = segment };
            count += 1;
        }
        if (segments.next() != null) return false;
        self.accept(params[0..count]);
        return true;
    }
    /// What wildcard `name` of the last matching pattern took, or empty.
    pub fn param(self: *const Route, name: []const u8) []const u8 {
        for (self.params[0..self.param_count]) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return "";
    }
    /// The value of query parameter `name`, as written; null without one.
    pub fn query(self: *const Route, name: []const u8) ?[]const u8 {
        return queryOf(self.location, name);
    }
    /// Name the page: it is the page's accessible name, announced as it
    /// is shown, and kept with its history entry for menus of pages.
    /// Longer titles are cut at a character boundary.
    pub fn title(self: *Route, text: []const u8) void {
        const entry = self.entry;
        var length = @min(text.len, max_title);
        while (length > 0 and length < text.len and text[length] & 0xc0 == 0x80) length -= 1;
        @memcpy(entry.title_bytes[0..length], text[0..length]);
        entry.title_len = @intCast(length);
    }

    fn accept(self: *Route, params: []const Param) void {
        @memcpy(self.params[0..params.len], params);
        self.param_count = params.len;
    }
    /// Key the page by the part of the path the layout takes, unless its
    /// content was already built.
    fn layout(self: *Route, prefix: []const u8) void {
        const node = &self.view.buffers.nodes[self.node];
        if (node.kind != .route or node.child_count != 0) return;
        const parent = &self.view.buffers.nodes[node.parent];
        var hasher = std.hash.Wyhash.init(parent.id);
        hasher.update("layout");
        hasher.update(std.mem.asBytes(&@intFromPtr(self.router)));
        hasher.update(prefix);
        const id = hasher.final();
        node.id = if (id == 0) 1 else id;
    }
};

/// Per-pass routing state of a View.
pub const PassState = struct {
    /// The first router built in this pass, which takes the keys when the
    /// focus is in no router.
    first: ?*Router = null,
    first_rtl: bool = false,
    /// A router with the focus took the keys in this pass.
    bound: bool = false,
};

/// Open the page `router` shows as a column (close it with `end`) and
/// return its route; see `Route.match`. The column grows to fill its
/// parent unless `style` says otherwise.
pub fn route(v: *View, router: *Router, style: Style) view.Error!*Route {
    // Keys and buttons act in their own passes, before the page is built.
    if (v.takeEvent(router.actionId("back")) != null) router.back();
    if (v.takeEvent(router.actionId("forward")) != null) router.forward();
    const entry = router.shownEntry();
    var value = style;
    if (value.grow == 0 and value.height == null) value.grow = 1;
    if (value.self_align == null) value.self_align = .stretch;
    value.key = entry.page;
    const node = try v.openNode(.route, value);
    node.router = router;
    if (v.routes.first == null) {
        v.routes.first = router;
        v.routes.first_rtl = node.rtl;
    }
    const index: u32 = @intCast(node - v.buffers.nodes.ptr);
    router.route = .{ .router = router, .view = v, .node = index, .entry = entry, .page = entry.page, .location = try v.copyText(entry.location()) };
    return &router.route;
}

/// Called by `end` for a page: name it, move the focus or announce the
/// page after a change, remember the focus, and take the history keys
/// when the focus is in it.
pub fn close(v: *View, index: u32) view.Error!void {
    const all = v.buffers.nodes[0..v.len];
    const node = &all[index];
    const router = node.router.?;
    // The page built, even when the build went to another one meanwhile;
    // the next pass shows that one.
    const entry = router.route.entry;
    node.style.name = try v.copyText(entry.title());
    const focused = v.focus;
    const inside = if (focused) |id| within(all, index, id) else false;
    const changed = if (router.shown) |shown| shown != router.route.page else false;
    // The focus is still where it was in the page that left, as after
    // Alt+Left there, rather than on a control outside that chose the page.
    const left_with_page = if (focused) |id| if (router.focus_in_page) |was| was == id else false else false;
    if (changed) {
        if (left_with_page and !inside) {
            // The focus left with the page: it goes into the new one.
            const remembered = if (entry.focus) |id| if (within(all, index, id)) id else null else null;
            if (remembered orelse firstFocusable(all, index)) |id| v.restore = id;
        } else if (entry.title_len > 0) v.announce(entry.title());
    }
    router.shown = router.route.page;
    router.focus_in_page = if (inside) focused else null;
    if (inside) entry.focus = focused;
    if (inside and !v.routes.bound) {
        try bindKeys(v, router, node.rtl);
        v.routes.bound = true;
    }
}

/// Called by `finish`: without a router holding the focus, the first one
/// built takes the history keys.
pub fn finish(v: *View) view.Error!void {
    defer v.routes = .{};
    if (v.routes.bound) return;
    const router = v.routes.first orelse return;
    try bindKeys(v, router, v.routes.first_rtl);
}

fn bindKeys(v: *View, router: *Router, rtl: bool) view.Error!void {
    const back_id = router.actionId("back");
    const forward_id = router.actionId("forward");
    const alt: z.KeyModifiers = .{ .alt = true };
    // Back points toward the start of the line. At the ends of the history
    // the keys are left to other controls.
    if (router.canGoBack()) {
        try v.bindKey(.{ .key = if (rtl) .right else .left, .modifiers = alt, .allow_repeat = true }, true, back_id);
        try v.bindKey(.{ .key = .browser_back, .allow_repeat = true }, true, back_id);
    }
    if (router.canGoForward()) {
        try v.bindKey(.{ .key = if (rtl) .left else .right, .modifiers = alt, .allow_repeat = true }, true, forward_id);
        try v.bindKey(.{ .key = .browser_forward, .allow_repeat = true }, true, forward_id);
    }
}

pub const HistoryTexts = struct {
    back: []const u8 = "Back",
    forward: []const u8 = "Forward",
};

/// A button going back in `router`'s history, disabled at its start and
/// named "Back" unless `Style.name` says otherwise; right to left its
/// chevron points right. True for the pass it went back.
pub fn backButton(v: *View, router: *Router, style: Style) view.Error!bool {
    return historyButton(v, router, .back, style);
}
/// A button going forward again, as `backButton` goes back.
pub fn forwardButton(v: *View, router: *Router, style: Style) view.Error!bool {
    return historyButton(v, router, .forward, style);
}

fn historyButton(v: *View, router: *Router, direction: view.NavDirection, style: Style) view.Error!bool {
    const texts: HistoryTexts = .{};
    var value = style;
    if (value.name.len == 0) value.name = if (direction == .back) texts.back else texts.forward;
    const can = if (direction == .back) router.canGoBack() else router.canGoForward();
    value.enabled = value.enabled and can;
    if (!try v.navButton(direction, value)) return false;
    if (!can) return false;
    if (direction == .back) router.back() else router.forward();
    return true;
}

fn within(all: []const view.Node, index: u32, id: u64) bool {
    for (all[index..all[index].end]) |*inner| if (inner.id == id) return true;
    return false;
}

fn firstFocusable(all: []const view.Node, index: u32) ?u64 {
    for (all[index + 1 .. all[index].end]) |*node| {
        if (!node.style.enabled) continue;
        const focusable = switch (node.kind) {
            .button, .link, .nav_button, .combo_box, .popup_button, .checkbox, .radio, .segment, .tab, .list_item, .disclosure, .toggle_switch, .slider, .stepper, .rating, .token, .editable_text => true,
            .tree_row => node.cursor,
            .embed => node.embed.?.focusable,
            else => false,
        };
        if (focusable) return node.id;
    }
    return null;
}

/// The path of a location: up to its query.
pub fn pathOf(location: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, location, '?') orelse location.len;
    return location[0..end];
}

fn queryOf(location: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, location, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, location[start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..split], name)) return if (split < pair.len) pair[split + 1 ..] else "";
    }
    return null;
}

/// Resolve `target` against the location `base` as a link in a web page
/// is, into `out`: an absolute or relative path, cleaned of "." and ".."
/// parts and repeated slashes, with the target's query, or only a query,
/// which keeps the base's path.
pub fn resolve(out: *[max_location]u8, base: []const u8, target: []const u8) Error![]const u8 {
    for (target) |byte| if (byte < 0x20 or byte == 0x7f or byte == '#') return error.InvalidLocation;
    if (!std.unicode.utf8ValidateSlice(target)) return error.InvalidLocation;
    const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const target_path = target[0..split];
    const target_query = target[split..];
    // Only a query (or nothing) keeps the base's path.
    var scratch: [2 * max_location + 1]u8 = undefined;
    var joined: []const u8 = undefined;
    if (target_path.len == 0) {
        joined = pathOf(base);
    } else if (target_path[0] == '/') {
        joined = target_path;
    } else {
        // Relative to the base's directory: up to its last slash.
        const base_path = pathOf(base);
        const dir_end = (std.mem.lastIndexOfScalar(u8, base_path, '/') orelse 0) + 1;
        if (dir_end + target_path.len > scratch.len) return error.LocationTooLong;
        @memcpy(scratch[0 .. dir_end - 1], base_path[0 .. dir_end - 1]);
        scratch[dir_end - 1] = '/';
        @memcpy(scratch[dir_end..][0..target_path.len], target_path);
        joined = scratch[0 .. dir_end + target_path.len];
    }
    // Clean the parts into `out`.
    var len: usize = 0;
    var parts: [max_location / 2 + 1][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, joined, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count > 0) count -= 1;
            continue;
        }
        if (count == parts.len) return error.LocationTooLong;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) {
        out[0] = '/';
        len = 1;
    }
    for (parts[0..count]) |part| {
        if (len + 1 + part.len > out.len) return error.LocationTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..part.len], part);
        len += 1 + part.len;
    }
    // A query of its own, or none: "?" alone clears it.
    const query = if (target_query.len > 1) target_query else "";
    if (len + query.len > out.len) return error.LocationTooLong;
    @memcpy(out[len..][0..query.len], query);
    return out[0 .. len + query.len];
}

test "resolve follows web links" {
    var buffer: [max_location]u8 = undefined;
    try std.testing.expectEqualStrings("/notes/edit", try resolve(&buffer, "/notes/42", "edit"));
    try std.testing.expectEqualStrings("/settings", try resolve(&buffer, "/notes/edit", "../settings/"));
    try std.testing.expectEqualStrings("/settings?tab=fonts", try resolve(&buffer, "/settings", "?tab=fonts"));
    try std.testing.expectEqualStrings("/a/c", try resolve(&buffer, "/x", "/a/./b/../c"));
    try std.testing.expectEqualStrings("/", try resolve(&buffer, "/a", "../.."));
    try std.testing.expectError(error.InvalidLocation, resolve(&buffer, "/", "/a#b"));
    try std.testing.expectError(error.LocationTooLong, resolve(&buffer, "/", "/" ++ &@as([300]u8, @splat('x'))));
}

test "history pushes, replaces and moves" {
    var storage: [4]RouteEntry = undefined;
    var router = try Router.init(&storage, "/notes");
    try std.testing.expect(!router.canGoBack() and !router.canGoForward());
    try router.push("/notes/42");
    try router.push("edit");
    try std.testing.expectEqualStrings("/notes/edit", router.location());
    try router.push("../settings/");
    try router.push("?tab=fonts");
    try std.testing.expectEqualStrings("/settings?tab=fonts", router.location());
    try std.testing.expectEqualStrings("fonts", router.query("tab").?);
    try std.testing.expectEqualStrings("/settings", router.path());
    // Four entries hold the history: the oldest went.
    try std.testing.expectEqual(@as(usize, 4), router.len);
    try std.testing.expectEqualStrings("/notes/42", router.entryAt(-3).?.location());
    try std.testing.expect(router.entryAt(-4) == null);
    // The same path with another query is the same page.
    try std.testing.expectEqual(router.entryAt(-1).?.page, router.entryAt(0).?.page);
    router.back();
    try std.testing.expectEqualStrings("/settings", router.location());
    try std.testing.expect(router.canGoForward());
    router.go(-10);
    try std.testing.expectEqualStrings("/notes/42", router.location());
    router.go(10);
    try std.testing.expectEqualStrings("/settings?tab=fonts", router.location());
    router.go(-2);
    // Pushing forgets the pages after.
    try router.push("/c");
    try std.testing.expect(!router.canGoForward());
    const page = router.entryAt(0).?.page;
    try router.replace("?x=1");
    try std.testing.expectEqual(page, router.entryAt(0).?.page);
    try router.replace("/d");
    try std.testing.expect(page != router.entryAt(0).?.page);
    try std.testing.expectEqualStrings("/notes/edit", router.entryAt(-1).?.location());
    // Pushing what is shown changes nothing.
    try router.push("/d");
    try std.testing.expect(!router.canGoForward());
    try std.testing.expectEqualStrings("/notes/edit", router.entryAt(-1).?.location());
}

test "patterns take parts and the rest" {
    var nodes: [4]view.Node = undefined;
    var text: [512]u8 = undefined;
    var items: [4]view.layout.Item = undefined;
    var rects: [4]view.Rect = undefined;
    var v = View.init(.{ .nodes = &nodes, .text = &text, .items = &items, .rects = &rects });
    v.reset(.{}, null);
    var storage: [2]RouteEntry = undefined;
    var router = try Router.init(&storage, "/");
    const cases = [_]struct { path: []const u8, pattern: []const u8, ok: bool, name: []const u8 = "", value: []const u8 = "" }{
        .{ .path = "/", .pattern = "/", .ok = true },
        .{ .path = "/", .pattern = "/notes", .ok = false },
        .{ .path = "/notes", .pattern = "/notes/", .ok = true },
        .{ .path = "/notes/42", .pattern = "/notes", .ok = false },
        .{ .path = "/notes/42", .pattern = "/notes/{id}", .ok = true, .name = "id", .value = "42" },
        .{ .path = "/notes/42/edit", .pattern = "/notes/{id}", .ok = false },
        .{ .path = "/notes/42/edit", .pattern = "/notes/{id}/edit", .ok = true, .name = "id", .value = "42" },
        .{ .path = "/files", .pattern = "/files/{path...}", .ok = true, .name = "path", .value = "" },
        .{ .path = "/files/docs/a.txt", .pattern = "/files/{path...}", .ok = true, .name = "path", .value = "docs/a.txt" },
        .{ .path = "/users/ada/files/x", .pattern = "/users/{name}/files/{rest...}", .ok = true, .name = "name", .value = "ada" },
        .{ .path = "/a", .pattern = "/{rest...}/b", .ok = false },
    };
    for (cases) |case| {
        var r: Route = .{ .router = &router, .view = &v, .node = 0, .entry = &storage[0], .page = 1, .location = case.path };
        try std.testing.expectEqual(case.ok, r.match(case.pattern));
        if (case.name.len > 0) try std.testing.expectEqualStrings(case.value, r.param(case.name));
    }
    // A pattern that does not match keeps the parameters of the last that did.
    var r: Route = .{ .router = &router, .view = &v, .node = 0, .entry = &storage[0], .page = 1, .location = "/notes/42?tab=a" };
    try std.testing.expect(r.match("/notes/{id}"));
    try std.testing.expect(!r.match("/notes/{id}/edit"));
    try std.testing.expectEqualStrings("42", r.param("id"));
    try std.testing.expectEqualStrings("a", r.query("tab").?);
}
