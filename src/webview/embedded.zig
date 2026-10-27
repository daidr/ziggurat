//! Web views shown inside a window of declarative native UI: `WebView.show`
//! lays a page out like any leaf, and the window's `WebViews` keeps each
//! page's native region on the leaf's box after every frame, hiding pages
//! the frame no longer builds.
//!
//! The window's Content is a `composition.Owner`. The Host draws the full
//! window backdrop and every web view is a native rectangular region above
//! it, so native UI painted where a page shows stays under the page.
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
        var changed = false;
        for (self.items) |entry| {
            const item = entry orelse continue;
            item.wanted = if (item.placed) |bounds| .{ .bounds = bounds, .visible = true } else hidden;
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
            if (std.meta.eql(item.wanted, item.applied)) continue;
            const region = item.region orelse continue;
            region.update(item.wanted) catch |err| {
                self.last_error = self.last_error orelse err;
                continue;
            };
            item.applied = item.wanted;
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
    placed: ?view.Rect = null,
    wanted: z.composition.Viewport = hidden,
    applied: z.composition.Viewport = hidden,

    /// The leaf to emit with `View.embed`.
    pub fn embed(self: *WebView) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint };
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
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *WebView = @ptrCast(@alignCast(ptr));
        if (bounds.width <= 0 or bounds.height <= 0) return;
        if (frame.clipBounds()) |clip| {
            if (clip.x >= bounds.x + bounds.width or clip.y >= bounds.y + bounds.height or bounds.x >= clip.x + clip.width or bounds.y >= clip.y + clip.height) return;
        }
        self.placed = bounds;
    }
};
