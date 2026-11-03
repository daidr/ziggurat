//! Web views shown inside a window of declarative native UI: `WebView.show`
//! lays a page out like any leaf, and the window's `WebViews` keeps each
//! page's native region on the leaf's box after every frame, hiding pages
//! the frame no longer builds.
//!
//! The window's Content is a `composition.Owner`. The Host draws the full
//! window backdrop and every web view is a native region with it. On Linux
//! and macOS the native UI shows over the page outside the clips around its
//! leaf and where it paints after the leaf: its popovers, menus, dialogs and
//! the controls over it take the pointer there, and the page takes no
//! pointer behind a modal dialog. On Linux the page is under the native UI,
//! which is cut away where the page shows; on macOS the page is over it and
//! is masked where the native UI shows. On Windows the page is a native
//! child over the window and native UI painted where it shows stays under
//! it. A page is cut to its leaf's corner radius, and a page the poses
//! around it scale shows scaled at the size its leaf was arranged at, as a
//! picture of it, rather than laid out again.
//!
//! The leaf is a Tab stop: Tab moving the focus to it gives the page the
//! keyboard at its first element, Shift+Tab at its last (Linux and macOS),
//! and Tab past the page's other end moves the focus on from the leaf.
//! Assistive technology finds the page's tree inside the leaf's semantic
//! node.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const web = @import("ziggurat_webview");

/// Web views per window.
pub const max_web_views = 16;

const hidden: z.composition.Viewport = .{ .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .visible = false };

/// The web views of one window. Keep it at a stable address from `init`
/// until every web view was removed, and install `hook` as the Host's
/// `Options.after_frame`.
pub const WebViews = struct {
    host: *view.Host,
    owner: *z.composition.Owner,
    items: [max_web_views]?*WebView = @splat(null),
    queued: bool = false,
    /// The first error placing a page since the last `takeError`.
    last_error: ?anyerror = null,

    pub fn init(host: *view.Host, owner: *z.composition.Owner) WebViews {
        return .{ .host = host, .owner = owner };
    }
    /// The Host's `after_frame` hook.
    pub fn hook(self: *WebViews) view.FrameHook {
        return .{ .context = self, .run = afterFrame };
    }
    /// Show `page` in this window: reserve its region, hidden until a frame
    /// builds `item`, and attach the page there with `options`. `item` and
    /// `page` stay at stable addresses until `WebView.remove`.
    pub fn add(self: *WebViews, item: *WebView, page: *web.View, options: web.Options) !void {
        const slot = for (&self.items) |*entry| {
            if (entry.* == null) break entry;
        } else return error.Full;
        const region = try self.owner.reserve(hidden);
        errdefer _ = region.remove() catch false;
        item.* = .{ .set = self, .page = page, .region = region };
        try page.attachRegion(region, options);
        slot.* = item;
    }
    pub fn takeError(self: *WebViews) ?anyerror {
        defer self.last_error = null;
        return self.last_error;
    }

    fn afterFrame(ptr: *anyopaque) void {
        const self: *WebViews = @ptrCast(@alignCast(ptr));
        const state = &self.host.context.input_state;
        // The controls this frame added, in paint order.
        const hits = if (state.building) state.pending[0..state.pending_len] else state.hits[0..state.len];
        var changed = false;
        for (self.items) |entry| {
            const item = entry orelse continue;
            if (item.placed) |*shown| item.cover(shown, hits);
            item.wanted = if (item.placed) |shown| shown else hidden;
            // Tab or a request moved the focus to the leaf: the page takes
            // the keyboard.
            const focused = item.placed != null and item.node != 0 and state.focused == item.node;
            if (focused and !item.had_focus) {
                item.keyboard = if (state.tab_serial == item.tab_seen) .plain else if (state.tab_backward) .back else .forward;
                changed = true;
            }
            item.had_focus = focused;
            item.tab_seen = state.tab_serial;
            item.placed = null;
            if (!std.meta.eql(item.wanted, item.applied)) changed = true;
        }
        if (!changed or self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = apply }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.queued = true;
    }
    /// Posted after paint: move, resize, show and hide the native regions.
    fn apply(ptr: *anyopaque) void {
        const self: *WebViews = @ptrCast(@alignCast(ptr));
        self.queued = false;
        for (self.items) |entry| {
            const item = entry orelse continue;
            const region = item.region orelse continue;
            if (!std.meta.eql(item.wanted, item.applied)) {
                region.update(item.wanted) catch |err| {
                    self.last_error = self.last_error orelse err;
                    continue;
                };
                item.applied = item.wanted;
            }
            const keyboard = item.keyboard;
            item.keyboard = .none;
            if (keyboard == .none or !item.applied.visible or item.page.holdsKeyboard()) continue;
            item.page.tabInto(keyboard == .back) catch |err| {
                // Elsewhere the page keeps the keyboard it has.
                const known: anyerror = err;
                if (known != error.UnsupportedCapability and known != error.NotReady) self.last_error = self.last_error orelse err;
            };
        }
    }
};

/// A page shown in the native UI. It has no size of its own: give its leaf
/// `Style.grow`, a stretch alignment or a size. The page fills the leaf's
/// box; a frame that does not build it, or clips it away entirely, hides
/// the page and keeps it where it was.
pub const WebView = struct {
    set: *WebViews,
    page: *web.View,
    region: ?z.composition.Region,
    /// Where this frame placed the leaf, if it did.
    placed: ?z.composition.Viewport = null,
    /// How the leaf shows, told just before its paint.
    shown: view.Presentation = .{ .frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 } },
    wanted: z.composition.Viewport = hidden,
    applied: z.composition.Viewport = hidden,
    /// The leaf's node, and how many controls the frame had added before
    /// those painted after it.
    node: u64 = 0,
    mark: usize = 0,
    /// The field around the leaf and its semantic parent.
    about: view.Annotation = .{},
    /// Whether the leaf had the focus in the last frame, the Tab moves
    /// seen then, and the keyboard the page is to take.
    had_focus: bool = false,
    tab_seen: u32 = 0,
    keyboard: enum { none, plain, forward, back } = .none,

    /// The leaf to emit with `View.embed`.
    pub fn embed(self: *WebView) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .present = present, .annotate = annotate, .focusable = true, .holds_keyboard = holdsKeyboard };
    }
    /// Emit the leaf with `style`.
    pub fn show(self: *WebView, v: *view.View, style: view.Style) view.Error!void {
        try v.embed(self.embed(), style);
    }
    /// Close the page's region, which closes the page, and forget it.
    pub fn remove(self: *WebView) void {
        for (&self.set.items) |*entry| {
            if (entry.* == self) entry.* = null;
        }
        if (self.region) |region| _ = region.remove() catch false;
        self.region = null;
    }

    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn present(ptr: *anyopaque, _: u64, shown: view.Presentation) void {
        const self: *WebView = @ptrCast(@alignCast(ptr));
        self.shown = shown;
    }
    fn annotate(ptr: *anyopaque, about: view.Annotation) void {
        const self: *WebView = @ptrCast(@alignCast(ptr));
        self.about = about;
    }
    fn holdsKeyboard(ptr: *anyopaque) bool {
        const self: *WebView = @ptrCast(@alignCast(ptr));
        return self.page.holdsKeyboard();
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: view.Rect) anyerror!void {
        const self: *WebView = @ptrCast(@alignCast(ptr));
        defer self.shown = .{ .frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
        self.node = id;
        self.mark = frame.inertMark().controls;
        if (bounds.width <= 0 or bounds.height <= 0) return;
        var placed = viewportOf(bounds, self.shown);
        if (frame.clipBounds()) |clip| {
            placed.clip = clip;
            const box = placed.shown();
            if (box.width <= 0 or box.height <= 0) return;
        }
        self.placed = placed;
        // The page's tree is inside this node.
        try frame.semantic(.{ .id = id, .parent = self.about.parent, .role = .group, .name = self.about.name, .description = self.about.description, .bounds = placed.shown(), .native = self.page.accessibleNative() });
    }
    /// Add to `shown` the boxes of the controls painted after the leaf that
    /// show over its page; all of it when the leaf is inert, as behind a
    /// modal dialog.
    fn cover(self: *WebView, shown: *z.composition.Viewport, hits: []const ui.Hit) void {
        const start = @min(self.mark, hits.len);
        // The leaf's own control is the one before the mark.
        if (start > 0 and hits[start - 1].id == self.node and !hits[start - 1].options.enabled) {
            shown.addCover(shown.shown());
            return;
        }
        for (hits[start..]) |hit| {
            if (hit.id == self.node or hit.options.pass_through) continue;
            shown.addCover(hit.rect);
        }
    }
    /// The page's region for a leaf arranged at `bounds` that shows as
    /// `shown`: in its frame, laid out at the arranged size when the poses
    /// scale it, inside its corners.
    fn viewportOf(bounds: view.Rect, shown: view.Presentation) z.composition.Viewport {
        const told = shown.frame.width > 0 and shown.frame.height > 0;
        const scaled = told and (@abs(shown.scale[0] - 1) > 1e-6 or @abs(shown.scale[1] - 1) > 1e-6);
        const radius = if (std.math.isFinite(shown.radius) and shown.radius > 0) @min(shown.radius, @min(bounds.width, bounds.height) / 2) else 0;
        return .{
            .bounds = if (told) shown.frame else bounds,
            .layout_width = if (scaled) bounds.width else 0,
            .layout_height = if (scaled) bounds.height else 0,
            .radii = @splat(radius),
        };
    }
};

test "a web view's region follows the poses that scale its leaf and cuts it to its corners" {
    const bounds: view.Rect = .{ .x = 10, .y = 20, .width = 200, .height = 100 };
    const plain = WebView.viewportOf(bounds, .{ .frame = bounds });
    try std.testing.expectEqualDeep(bounds, plain.bounds);
    try std.testing.expectEqual(@as(f32, 0), plain.layout_width);
    try std.testing.expect(!plain.rounded());
    const half: view.Rect = .{ .x = 60, .y = 45, .width = 100, .height = 50 };
    const shown = WebView.viewportOf(bounds, .{ .frame = half, .scale = .{ 0.5, 0.5 }, .radius = 12 });
    try std.testing.expectEqualDeep(half, shown.bounds);
    try std.testing.expectEqual([2]f32{ 200, 100 }, shown.layoutSize());
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, shown.scale());
    try std.testing.expectEqual([4]f32{ 12, 12, 12, 12 }, shown.radii);
    // A radius past half the box's side is the pill's.
    try std.testing.expectEqual(@as(f32, 50), WebView.viewportOf(bounds, .{ .frame = bounds, .radius = 999 }).radii[0]);
}
