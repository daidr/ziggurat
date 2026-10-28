//! An editor of attributed text as a leaf of declarative views, as word
//! processors edit it: bold, italic, underline, strikethrough, code, sizes
//! and colors, links, headings, lists, tasks, quotations, blocks of code,
//! alignment and attachments, with the shortcuts of word processors
//! (Ctrl+B, Ctrl+I, Ctrl+U, Ctrl+K, Ctrl+Shift+7, Ctrl+Shift+8, Ctrl+], …),
//! Markdown shortcuts as one types ("# ", "- ", **bold**, `code`), undo of
//! formats with the text, rich copy and paste, and input methods composing
//! in the typing attributes.
//!
//! The application keeps a `Document` and an `Editor` of it at stable
//! addresses, emits the editor with `emit` (or `View.embed(editor.embed())`)
//! and formats the selection through the document (`toggleBold`,
//! `setHeading`, …), showing its formats with `Document.formatting`. The
//! editor lays out only the paragraphs in view, so a long document edits as
//! a short one. Laying out, registering with the UI Context and placing the
//! input method's caret run as tasks posted after paint, never inside it;
//! the window's Context needs `prepareTextFields` before the editor shows.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const fonts = @import("ziggurat_fonts");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const rt = @import("ziggurat_rich_text");
const lay = @import("layout.zig");
const Heights = @import("heights.zig").Heights;

const Allocator = std.mem.Allocator;
const Text = rt.Text;
const Document = rt.Document;
const Attributes = rt.Attributes;
const ParagraphStyle = rt.ParagraphStyle;
const Layout = lay.Layout;
const Affinity = lay.Affinity;
pub const Rect = view.Rect;
pub const Point = view.Point;

// ---- Theme -----------------------------------------------------------------

/// How headings of one level look; what is left zero takes the default.
pub const HeadingStyle = struct {
    /// Size in ems of the text: 1.8, 1.45, 1.2, 1.1, 1 and 0.9 by level.
    size: f32 = 0,
    /// 700 by default.
    weight: u16 = 0,
    color: ?u32 = null,
    /// Room above, in ems of the heading, unless it starts the text: 0.6.
    /// Below, in ems of the text: 0.25.
    top: f32 = 0,
    bottom: f32 = 0,
};

/// How the editor's text looks. What it leaves null or zero takes the
/// default for the window's theme, so a theme sets only what it changes.
/// Lengths in ems are times the editor's font size.
pub const Theme = struct {
    /// Text, the placeholder and tasks done, links.
    text: ?u32 = null,
    muted: ?u32 = null,
    link: ?u32 = null,
    caret: ?u32 = null,
    selection: ?ui.Color = null,
    /// Code within text and in blocks: its size in ems (0.92), its color,
    /// and what is behind it.
    code_size: f32 = 0,
    code: ?u32 = null,
    code_background: ?ui.Color = null,
    code_block_background: ?ui.Color = null,
    /// Corners of blocks of code in ems (0.3), and the room inside them
    /// in ems: 0.7 across, 0.5 at their top and bottom.
    code_block_radius: f32 = 0,
    code_block_padding: [2]f32 = .{ 0, 0 },
    headings: [6]HeadingStyle = @splat(.{}),
    /// How far a level of a list or of indentation goes, in ems: 1.7.
    indent: f32 = 0,
    /// Bullets and numbers; the fill and check of tasks done.
    marker: ?u32 = null,
    checkbox: ?u32 = null,
    checkmark: ?u32 = null,
    /// The bar along quotations, its width in DIP (3), and their text.
    quote_bar: ?u32 = null,
    quote_bar_width: f32 = 0,
    quote_text: ?u32 = null,
    /// Room around the text, in DIP across and down: 12 and 10.
    padding: ?[2]f32 = null,
};

const heading_sizes = [6]f32{ 1.8, 1.45, 1.2, 1.1, 1, 0.9 };

/// A theme with nothing left to default.
pub const Look = struct {
    text: u32,
    muted: u32,
    link: u32,
    caret: u32,
    selection: ui.Color,
    border: u32,
    code_size: f32,
    code: u32,
    code_background: ui.Color,
    code_block_background: ui.Color,
    code_block_radius: f32,
    code_block_padding: [2]f32,
    headings: [6]struct { size: f32, weight: u16, color: u32, top: f32, bottom: f32 },
    indent: f32,
    marker: u32,
    checkbox: u32,
    checkmark: u32,
    quote_bar: u32,
    quote_bar_width: f32,
    quote_text: u32,
    padding: [2]f32,
};

fn alpha(rgb: u32, a: f32) ui.Color {
    var c = ui.Color.rgb(rgb);
    c.a = @intFromFloat(std.math.clamp(a * 255, 0, 255));
    return c;
}

/// `theme` with what it leaves out taken from the window's theme.
pub fn resolve(theme: Theme, window: ui.Theme) Look {
    const p = window.palette;
    const text = theme.text orelse p.text;
    const muted = theme.muted orelse p.disabled_text;
    var look: Look = .{
        .text = text,
        .muted = muted,
        .link = theme.link orelse p.accent,
        .caret = theme.caret orelse p.accent,
        .selection = theme.selection orelse alpha(p.accent, 0.3),
        .border = p.border,
        .code_size = if (theme.code_size > 0) theme.code_size else 0.92,
        .code = theme.code orelse text,
        .code_background = theme.code_background orelse alpha(text, 0.07),
        .code_block_background = theme.code_block_background orelse alpha(text, 0.07),
        .code_block_radius = if (theme.code_block_radius > 0) theme.code_block_radius else 0.3,
        .code_block_padding = .{ if (theme.code_block_padding[0] > 0) theme.code_block_padding[0] else 0.7, if (theme.code_block_padding[1] > 0) theme.code_block_padding[1] else 0.5 },
        .headings = undefined,
        .indent = if (theme.indent > 0) theme.indent else 1.7,
        .marker = theme.marker orelse text,
        .checkbox = theme.checkbox orelse p.accent,
        .checkmark = theme.checkmark orelse 0xffffff,
        .quote_bar = theme.quote_bar orelse p.border,
        .quote_bar_width = if (theme.quote_bar_width > 0) theme.quote_bar_width else 3,
        .quote_text = theme.quote_text orelse muted,
        .padding = theme.padding orelse .{ 12, 10 },
    };
    for (&look.headings, theme.headings, heading_sizes) |*h, t, size| h.* = .{
        .size = if (t.size > 0) t.size else size,
        .weight = if (t.weight > 0) t.weight else 700,
        .color = t.color orelse text,
        .top = if (t.top > 0) t.top else 0.6,
        .bottom = if (t.bottom > 0) t.bottom else 0.25,
    };
    return look;
}

// ---- Options ---------------------------------------------------------------

/// What a copy puts on the clipboard: the editor's own format (the JSON of
/// `rt.clip`, under `rt.clip.format`), HTML and plain text.
pub const Copied = struct { rich: []const u8, html: []const u8, text: []const u8 };

/// What the clipboard holds, in the formats the editor reads; empty for a
/// format it does not hold. `Editor.paste` takes the richest.
pub const Pasted = struct {
    rich: []const u8 = "",
    html: []const u8 = "",
    rtf: []const u8 = "",
    markdown: []const u8 = "",
    text: []const u8 = "",
};

/// The clipboard, which the application connects, as with the system's
/// `ziggurat_system` clipboard. A read answers with `Editor.paste`, before
/// it returns or later.
pub const Clipboard = struct {
    context: ?*anyopaque = null,
    write: *const fn (?*anyopaque, Copied) anyerror!void,
    /// `match_style` asks only for plain text, which takes the typing
    /// attributes.
    read: *const fn (?*anyopaque, *Editor, match_style: bool) anyerror!void,
};

/// Opens a URL.
pub const Opener = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8) void,
};

pub const Callback = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, *Editor) void,
};

/// Draws an attachment in its box; without one, the editor draws a box
/// with the attachment's name.
pub const AttachmentPainter = struct {
    context: ?*anyopaque = null,
    paint: *const fn (?*anyopaque, *ui.Frame, *const rt.Attachment, Rect) anyerror!void,
};

/// Styles the runs carrying a tag, as an application shows mentions.
pub const TagStyler = struct {
    context: ?*anyopaque = null,
    style: *const fn (?*anyopaque, []const u8, *lay.Style) void,
};

pub const Options = struct {
    /// Names the editor to assistive technology.
    name: []const u8 = "Rich text",
    /// Shows while the text is empty.
    placeholder: []const u8 = "",
    /// The text's font; headings and code scale it.
    font: view.Font = .{ .size = 14 },
    /// Measures text in its fonts; use the one the view host uses.
    measurer: view.Measurer = .{},
    /// Shows the text without letting the user change it: it is selected
    /// and copied, its links and tasks are clicked.
    read_only: bool = false,
    /// Turns off the Markdown shortcuts.
    no_markdown: bool = false,
    theme: Theme = .{},
    /// Draws a background and border, with room around the text; off, the
    /// text fills the leaf, for an editor of the application's own look.
    frame: bool = true,
    /// Preferred size before the parent's flex layout applies.
    width: f32 = 400,
    height: f32 = 240,
    clipboard: ?Clipboard = null,
    /// Opens a link clicked, whatever its URL, instead of `open_url`.
    on_link: ?Opener = null,
    /// The system's opener, given only the http, https and mailto URLs
    /// `safeToOpen` allows.
    open_url: ?Opener = null,
    /// Runs for Ctrl+K, as an application asks for the URL of a link in a
    /// popover and sets it with `Document.setLink`. Without it, Ctrl+K links
    /// a selected URL to itself.
    on_link_command: ?Callback = null,
    /// Runs after an edit the user made.
    on_change: ?Callback = null,
    attachment_painter: ?AttachmentPainter = null,
    tag_styler: ?TagStyler = null,
};

/// Whether the system may open `url`: http, https and mailto, without
/// controls or backslashes.
pub fn safeToOpen(url: []const u8) bool {
    for (url) |c| if (c < ' ' or c == 0x7f or c == '\\') return false;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "mailto");
}

/// The commands of a format menu and of the shortcuts.
pub const Command = union(enum) {
    bold,
    italic,
    underline,
    strikethrough,
    code,
    bullets,
    numbers,
    tasks,
    indent,
    outdent,
    align_left,
    align_center,
    align_right,
    quote,
    code_block,
    link,
    /// 0 for a body paragraph.
    heading: u8,
    copy,
    cut,
    paste,
    paste_and_match_style,
    select_all,
    delete,
    undo,
    redo,
};

/// The pointer's shape where it hovers: an arrow over task boxes and the
/// scroll bar, a hand over links, an I-beam over text.
pub const Cursor = enum { text, arrow, pointer };

const scrollbar_width = 10;
const blink_ns: u64 = 530 * std.time.ns_per_ms;
const blink_for_ns: u64 = 30 * std.time.ns_per_s;
/// How many paragraphs keep their layouts out of view.
const max_laid = 512;
/// The most of the text the accessibility value carries.
const max_value = 16 * 1024;

const StepMode = enum { new, typing, same };

/// What an editor made of a paragraph.
const ParaView = struct {
    id: u64,
    revision: u64,
    style: ParagraphStyle,
    /// Its first rune in the text, and its runes, as of the last sync.
    start: u32,
    n: u32,
    layout: Layout,
    laid: bool = false,
    /// The composition laid out in it, by its revision, and where.
    compose_revision: u64 = 0,
    compose_at: u32 = 0,
    composed: bool = false,
    /// Its height with the room around it, 0 until laid out, and the room.
    h: f32 = 0,
    space: f32 = 0,
    /// A marker of a list laid out for it.
    marker: [24]u8 = undefined,
    marker_len: u8 = 0,
};

const LookKey = struct { width: f32, font: view.Font, theme: ui.Theme, tags: bool };

/// Keep an Editor at a stable address while the view emits it and until
/// `detach`. The Document stays the application's.
pub const Editor = struct {
    host: *view.Host,
    allocator: Allocator,
    doc: *Document,
    options: Options,
    look: Look,
    window_theme: ui.Theme = .{},
    // Registration with the Context.
    id: u64 = 0,
    token: ?ui.TextFieldToken = null,
    client: ?z.TextClientToken = null,
    client_revision: u64 = 0,
    queued: bool = false,
    caret_rect: ?z.Rect = null,
    caret_sent: ?z.Rect = null,
    /// Bounds of the last placement, in window DIP.
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    // What is laid out: the document's version and selection version.
    version: u64 = 0,
    selection_version: u64 = 0,
    paras: std.ArrayList(ParaView) = .empty,
    heights: Heights = .{},
    laid: usize = 0,
    laid_look: ?LookKey = null,
    /// Content width and height, without the padding.
    width: f32 = 0,
    view_height: f32 = 0,
    pad_x: f32 = 0,
    pad_y: f32 = 0,
    scroll: f64 = 0,
    anchor_para: usize = 0,
    anchor_offset: f64 = 0,
    reveal: bool = true,
    first: usize = 0,
    last: usize = 0,
    /// The selection as of the last sync, which paint shows.
    sel_anchor: u32 = 0,
    sel_caret: u32 = 0,
    affinity: Affinity = .downstream,
    desired_x: ?f32 = null,
    // An input method's composition, shown at the caret.
    compose: std.ArrayList(u8) = .empty,
    compose_runes: u32 = 0,
    /// Runes into the composition its caret is.
    compose_caret: u32 = 0,
    compose_revision: u64 = 1,
    composing: bool = false,
    // How the next edit joins the steps of undo.
    mode: StepMode = .new,
    coalesce: bool = false,
    // The pointer.
    dragging: bool = false,
    drag_unit: u8 = 1,
    drag_start: [2]u32 = .{ 0, 0 },
    press_link: std.ArrayList(u8) = .empty,
    thumb: bool = false,
    thumb_grab: f32 = 0,
    cursor: Cursor = .text,
    focused: bool = false,
    /// When the caret last moved, in the view's clock, and the time of the
    /// last pass: the caret blinks between them.
    blink_start: u64 = 0,
    now: u64 = 0,
    /// The numbers of the items of numbered lists, for the version.
    numbers: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    numbers_version: u64 = 0,
    /// The accessibility value: the text, bounded.
    value: std.ArrayList(u8) = .empty,
    value_version: u64 = 0,
    /// The first error from deferred work or input, for diagnostics.
    last_error: ?anyerror = null,
    /// The user edited the text since `takeChanged`.
    changed: bool = false,

    pub fn init(host: *view.Host, allocator: Allocator, doc: *Document, options: Options) Editor {
        var e: Editor = .{ .host = host, .allocator = allocator, .doc = doc, .options = options, .look = resolve(options.theme, .{}) };
        e.setPadding();
        return e;
    }

    pub fn deinit(self: *Editor) void {
        for (self.paras.items) |*p| p.layout.deinit();
        self.paras.deinit(self.allocator);
        self.heights.deinit(self.allocator);
        self.compose.deinit(self.allocator);
        self.press_link.deinit(self.allocator);
        self.numbers.deinit(self.allocator);
        self.value.deinit(self.allocator);
        self.* = undefined;
    }

    /// The leaf to emit with `View.embed`. Give it a `Style.key` when
    /// siblings before it can change.
    pub fn embed(self: *Editor) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .status = status, .input = hoverInput };
    }

    /// Emits the leaf and asks for the passes the caret's blinking needs.
    pub fn emit(self: *Editor, v: *view.View, style: view.Style) view.Error!void {
        self.now = v.time();
        if (self.focused and !self.options.read_only) {
            const phase = self.now -| self.blink_start;
            if (phase < blink_for_ns) v.wakeAt(self.now + (blink_ns - phase % blink_ns));
        }
        try v.embed(self.embed(), style);
    }

    /// Unregisters from the Context and stops deferred work. Call before
    /// the Context detaches or the editor goes away; it can be shown again.
    pub fn detach(self: *Editor) void {
        if (self.client) |client| _ = client.window.clearTextClient(client) catch {};
        self.client = null;
        if (self.token) |token| _ = token.close() catch {};
        self.token = null;
        self.id = 0;
    }

    /// Whether the user edited the text since the last call.
    pub fn takeChanged(self: *Editor) bool {
        defer self.changed = false;
        return self.changed;
    }

    fn fail(self: *Editor, err: anyerror) void {
        self.last_error = self.last_error orelse err;
    }

    fn invalidate(self: *Editor) void {
        if (self.id == 0) return;
        if (self.host.context.window) |window| window.invalidate();
    }

    fn setPadding(self: *Editor) void {
        if (self.options.frame) {
            self.pad_x = self.look.padding[0];
            self.pad_y = self.look.padding[1];
        } else {
            self.pad_x = 0;
            self.pad_y = 0;
        }
    }

    // ---- Following the document ------------------------------------------

    fn text(self: *const Editor) *const Text {
        return &self.doc.text;
    }

    /// Gets the editor in step with its document: paragraphs that changed
    /// give up their layouts, and a selection the application set is taken.
    pub fn sync(self: *Editor) !void {
        const d = self.doc;
        if (d.version != self.version or self.paras.items.len != d.text.paragraphCount()) try self.remap();
        if (d.selection_version != self.selection_version) {
            self.selection_version = d.selection_version;
            self.affinity = .downstream;
            self.desired_x = null;
            self.dropCompose();
            self.reveal = true;
        }
        self.sel_anchor = d.anchor;
        self.sel_caret = d.caret;
    }

    fn dropCompose(self: *Editor) void {
        if (self.compose.items.len > 0) self.compose_revision += 1;
        self.compose.clearRetainingCapacity();
        self.compose_runes = 0;
        self.compose_caret = 0;
        self.composing = false;
    }

    /// The paragraph views of the text now: those of paragraphs that stay
    /// keep their layouts while they are the same, and their heights.
    fn remap(self: *Editor) !void {
        const allocator = self.allocator;
        const t = self.text();
        const n = t.paragraphCount();
        var old: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer old.deinit(allocator);
        try old.ensureTotalCapacity(allocator, @intCast(self.paras.items.len));
        for (self.paras.items, 0..) |p, i| old.putAssumeCapacity(p.id, @intCast(i));
        var next: std.ArrayList(ParaView) = .empty;
        errdefer next.deinit(allocator);
        try next.ensureTotalCapacity(allocator, n);
        const taken = try allocator.alloc(bool, self.paras.items.len);
        defer allocator.free(taken);
        @memset(taken, false);
        var start: u32 = 0;
        var anchor_id: ?u64 = if (self.anchor_para < self.paras.items.len) self.paras.items[self.anchor_para].id else null;
        var new_anchor: ?usize = null;
        var p: u32 = 0;
        while (p < n) : (p += 1) {
            const q = t.para(p);
            var pv: ParaView = .{ .id = q.id, .revision = q.revision, .style = q.style, .start = start, .n = q.n, .layout = Layout.init(allocator) };
            if (old.get(q.id)) |k| if (!taken[k]) {
                taken[k] = true;
                const was = &self.paras.items[k];
                pv.layout = was.layout;
                pv.h = was.h;
                pv.space = was.space;
                pv.laid = was.laid and was.revision == q.revision and was.style.eql(q.style);
                pv.compose_revision = was.compose_revision;
                pv.compose_at = was.compose_at;
                pv.composed = was.composed;
                pv.marker = was.marker;
                pv.marker_len = was.marker_len;
                if (!pv.laid) pv.marker_len = 0;
            };
            if (anchor_id != null and anchor_id.? == q.id) {
                new_anchor = p;
                anchor_id = null;
            }
            next.appendAssumeCapacity(pv);
            start += q.n + 1;
        }
        for (self.paras.items, taken) |*was, t_| if (!t_) was.layout.deinit();
        self.paras.deinit(allocator);
        self.paras = next;
        self.laid = 0;
        for (self.paras.items) |pv| {
            if (pv.laid) self.laid += 1;
        }
        if (new_anchor) |a| self.anchor_para = a else self.anchor_para = @min(self.anchor_para, n - 1);
        self.version = self.doc.version;
        try self.resetHeights();
    }

    fn resetHeights(self: *Editor) !void {
        const hs = try self.allocator.alloc(f32, self.paras.items.len);
        defer self.allocator.free(hs);
        for (self.paras.items, hs) |p, *h| h.* = p.h;
        try self.heights.reset(self.allocator, hs);
        self.estimate();
    }

    /// The height of paragraphs not laid out yet: the average of those
    /// that are, or a line of text.
    fn estimate(self: *Editor) void {
        const t = self.heights.totals();
        const n = self.paras.items.len - t.unknown;
        self.heights.estimate = if (n > 0) t.measured / @as(f64, @floatFromInt(n)) else self.options.font.size * 1.3;
    }

    // ---- Look ------------------------------------------------------------

    fn heading(self: *const Editor, level: u8) @TypeOf(self.look.headings[0]) {
        return self.look.headings[@min(@max(level, 1), 6) - 1];
    }

    /// The font of a paragraph of style st.
    fn paraFont(self: *const Editor, st: ParagraphStyle) view.Font {
        var f = self.options.font;
        if (st.heading > 0) {
            const h = self.heading(st.heading);
            f.size *= h.size;
            f.weight = weightOf(h.weight);
        } else if (st.code_block) {
            f.monospace = true;
            f.size *= self.look.code_size;
        }
        return f;
    }

    fn indentWidth(self: *const Editor) f32 {
        return self.options.font.size * self.look.indent;
    }

    /// The room left and right of a paragraph: its indentation, its list's
    /// marker, a quotation's bar, a block of code's padding.
    fn insets(self: *const Editor, st: ParagraphStyle) struct { left: f32, right: f32 } {
        const size = self.options.font.size;
        var left = @as(f32, @floatFromInt(st.indent)) * self.indentWidth();
        var right: f32 = 0;
        if (st.list != .none) left += self.indentWidth();
        if (st.quote) left += self.indentWidth() * 0.75;
        if (st.code_block) {
            left += size * self.look.code_block_padding[0];
            right += size * self.look.code_block_padding[0];
        }
        return .{ .left = left, .right = right };
    }

    /// The room above and below paragraph p: a heading's margins, a block
    /// of code's padding at its ends.
    fn space(self: *const Editor, p: usize, st: ParagraphStyle) struct { above: f32, below: f32 } {
        const size = self.options.font.size;
        const paras = self.paras.items;
        if (st.heading > 0) {
            const h = self.heading(st.heading);
            return .{ .above = if (p > 0) size * h.size * h.top else 0, .below = size * h.bottom };
        }
        if (st.code_block) {
            return .{
                .above = if (p == 0 or !paras[p - 1].style.code_block) size * self.look.code_block_padding[1] else 0,
                .below = if (p + 1 >= paras.len or !paras[p + 1].style.code_block) size * self.look.code_block_padding[1] else 0,
            };
        }
        return .{ .above = 0, .below = 0 };
    }

    /// How a run with attributes a looks in a paragraph of style st, in
    /// room `width`.
    fn spanStyle(self: *const Editor, a: Attributes, st: ParagraphStyle, base: view.Font, width: f32) lay.Style {
        const look = &self.look;
        var s: lay.Style = .{ .font = base, .underline = a.underline, .strikethrough = a.strikethrough };
        if (a.size > 0) s.font.size = a.size;
        if (a.weight > 0) s.font.weight = weightOf(a.weight);
        if (a.italic) s.font.italic = true;
        if (a.font.len > 0) applyFamily(&s.font, a.font);
        if (a.color.set()) s.color = a.color.value();
        if (a.background.set()) s.background = uiColor(a.background);
        if (a.code) {
            s.font.monospace = true;
            if (a.size == 0) s.font.size = self.options.font.size * look.code_size;
            if (s.background == null) s.background = look.code_background;
            s.radius = @max(3, s.font.size / 4);
        }
        if (a.link.len > 0) {
            if (s.color == null) s.color = look.link;
            s.underline = true;
        }
        if (st.list == .tasks and st.checked) {
            s.strikethrough = true;
            if (s.color == null) s.color = look.muted;
        }
        if (st.quote and s.color == null) s.color = look.quote_text;
        if ((a.code or st.code_block) and s.color == null and look.code != look.text) s.color = look.code;
        if (st.heading > 0 and s.color == null) {
            const c = self.heading(st.heading).color;
            if (c != look.text) s.color = c;
        }
        if (a.tag.len > 0) if (self.options.tag_styler) |styler| styler.style(styler.context, a.tag, &s);
        if (a.attachment) |at| {
            const size = at.size();
            var w = size.width;
            var h = size.height;
            if (width > 0 and w > width) {
                h = h * width / w;
                w = width;
            }
            s.object = .{ .width = w, .height = h };
        }
        return s;
    }

    fn lookKey(self: *const Editor) LookKey {
        return .{ .width = self.width, .font = self.options.font, .theme = self.window_theme, .tags = self.options.tag_styler != null };
    }

    // ---- Layout ------------------------------------------------------------

    /// Paragraph p laid out, with the composition at the caret.
    fn paraLayout(self: *Editor, p: usize) !*ParaView {
        const pv = &self.paras.items[p];
        const caret_para = self.paraAt(self.sel_caret);
        const composed = self.compose.items.len > 0 and caret_para == p;
        const at: u32 = if (composed) self.sel_caret - pv.start else 0;
        if (pv.laid and pv.composed == composed and (!composed or (pv.compose_revision == self.compose_revision and pv.compose_at == at))) {
            // The room around it follows its neighbours, which may have
            // changed without it: a block of code's last line, the first
            // heading.
            const sp = self.space(p, pv.style);
            if (sp.above + sp.below != pv.space) {
                const h = pv.h - pv.space + sp.above + sp.below;
                self.heights.add(p, h - pv.h, 0);
                pv.h = h;
                pv.space = sp.above + sp.below;
            }
            return pv;
        }
        const t = self.text();
        const q = t.para(@intCast(p));
        const ins = self.insets(pv.style);
        const room = @max(self.width - ins.left - ins.right, 1);
        const base = self.paraFont(pv.style);
        var spans: std.ArrayList(lay.Span) = .empty;
        defer spans.deinit(self.allocator);
        const typing = if (composed) self.doc.typingAttributes() else Attributes{};
        var done: u32 = 0;
        var placed = !composed;
        var it = q.iterator();
        while (it.next()) |item| {
            const n = rt.runeCount(item.run.text);
            const style = self.spanStyle(item.run.attributes, pv.style, base, room);
            if (!placed and done <= at and at < done + n) {
                const cut = rt.byteOfRune(item.run.text, at - done);
                if (cut > 0) try spans.append(self.allocator, .{ .text = item.run.text[0..cut], .style = style });
                try spans.append(self.allocator, .{ .text = self.compose.items, .style = self.spanStyle(typing, pv.style, base, room) });
                if (cut < item.run.text.len) try spans.append(self.allocator, .{ .text = item.run.text[cut..], .style = style });
                placed = true;
            } else try spans.append(self.allocator, .{ .text = item.run.text, .style = style });
            done += n;
        }
        if (!placed) try spans.append(self.allocator, .{ .text = self.compose.items, .style = self.spanStyle(typing, pv.style, base, room) });
        try pv.layout.build(spans.items, .{ .measurer = self.options.measurer, .font = base, .width = room, .@"align" = switch (pv.style.@"align") {
            .start => .start,
            .center => .center,
            .end => .end,
        } });
        const sp = self.space(p, pv.style);
        const h = sp.above + pv.layout.height + sp.below;
        if (!pv.laid) self.laid += 1;
        if (pv.h > 0) self.heights.add(p, h - pv.h, 0) else self.heights.add(p, h, -1);
        pv.h = h;
        pv.space = sp.above + sp.below;
        pv.laid = true;
        pv.composed = composed;
        pv.compose_revision = self.compose_revision;
        pv.compose_at = at;
        pv.marker_len = 0;
        return pv;
    }

    /// The paragraph holding rune i of the text laid out.
    fn paraAt(self: *const Editor, i: u32) usize {
        const paras = self.paras.items;
        var lo: usize = 0;
        var hi: usize = paras.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (paras[mid].start <= i) lo = mid else hi = mid;
        }
        return lo;
    }

    fn paraEnd(self: *const Editor, p: usize) u32 {
        return self.paras.items[p].start + self.paras.items[p].n;
    }

    fn textLen(self: *const Editor) u32 {
        const last = self.paras.items[self.paras.items.len - 1];
        return last.start + last.n;
    }

    /// Where the layout of paragraph p starts in the content.
    fn origin(self: *const Editor, p: usize) struct { x: f32, y: f64 } {
        const st = self.paras.items[p].style;
        return .{ .x = self.insets(st).left, .y = self.heights.top(p) + self.space(p, st).above };
    }

    /// Rune i of paragraph p in its layout, which holds the composition.
    fn local(self: *const Editor, p: usize, i: u32) u32 {
        const pv = &self.paras.items[p];
        var l = i -| pv.start;
        if (self.compose.items.len > 0 and i > self.sel_caret and self.paraAt(self.sel_caret) == p) l += self.compose_runes;
        return l;
    }

    /// The rune of the text at rune l of the layout of paragraph p.
    fn global(self: *const Editor, p: usize, l: u32) u32 {
        const pv = &self.paras.items[p];
        var r = l;
        if (self.compose.items.len > 0 and self.paraAt(self.sel_caret) == p) {
            const c = self.sel_caret - pv.start;
            if (r > c + self.compose_runes) r -= self.compose_runes else if (r > c) r = c;
        }
        return @min(pv.start + r, pv.start + pv.n);
    }

    /// The caret before rune i, extra runes into a composition there, in
    /// the content.
    fn caretAt(self: *Editor, i: u32, extra: u32, affinity: Affinity) !struct { x: f32, y: f64, h: f32 } {
        const p = self.paraAt(i);
        const pv = try self.paraLayout(p);
        const l = @min(self.local(p, i) + extra, pv.layout.runeCount());
        const c = pv.layout.caret(l, affinity);
        const o = self.origin(p);
        return .{ .x = o.x + c.x, .y = o.y + c.y, .h = c.height };
    }

    /// The paragraph nearest a point of the content and the rune of its
    /// layout there.
    fn layoutPositionAt(self: *Editor, x: f32, y_: f64) !struct { p: usize, l: u32, affinity: Affinity } {
        const n = self.paras.items.len;
        const y = @max(y_, 0);
        var p = self.heights.at(y);
        for (0..n) |_| {
            const pv = try self.paraLayout(p);
            const top = self.heights.top(p);
            if (y < top and p > 0) {
                p -= 1;
            } else if (y >= top + pv.h and p < n - 1) {
                p += 1;
            } else {
                const o = self.origin(p);
                const h = pv.layout.hit(.{ .x = x - o.x, .y = @floatCast(y - o.y) });
                return .{ .p = p, .l = h.rune, .affinity = h.affinity };
            }
        }
        return .{ .p = n - 1, .l = (try self.paraLayout(n - 1)).layout.runeCount(), .affinity = .downstream };
    }

    /// The caret position nearest a point of the content.
    fn positionAt(self: *Editor, x: f32, y: f64) !struct { i: u32, affinity: Affinity } {
        const at = try self.layoutPositionAt(x, y);
        return .{ .i = self.global(at.p, at.l), .affinity = at.affinity };
    }

    /// The edges of the visual line holding rune i.
    fn lineEdges(self: *Editor, i: u32) ![2]u32 {
        const p = self.paraAt(i);
        const pv = try self.paraLayout(p);
        const k = pv.layout.lineOf(self.local(p, i), self.affinity);
        const line = pv.layout.lines.items[k];
        var end = line.end;
        if (k + 1 < pv.layout.lines.items.len) {
            // Before the spaces a wrapped line ends with.
            while (end > line.start and isSpaceRune(pv.layout.runeAt(end - 1))) end -= 1;
        }
        return .{ self.global(p, line.start), self.global(p, end) };
    }

    fn setScroll(self: *Editor, y: f64) void {
        self.scroll = y;
        self.anchor_para = self.heights.at(y);
        self.anchor_offset = y - self.heights.top(self.anchor_para);
    }

    /// Lays out the paragraphs in view of a content box w×h, and those the
    /// caret is in when it is to be revealed.
    fn layoutView(self: *Editor, w: f32, h: f32) !void {
        self.width = w;
        const look_key = self.lookKey();
        if (self.laid_look == null or !std.meta.eql(self.laid_look.?, look_key)) {
            // Another width, font or theme: every paragraph anew.
            self.laid_look = look_key;
            for (self.paras.items) |*p| {
                p.laid = false;
                p.h = 0;
            }
            self.laid = 0;
            try self.resetHeights();
        }
        self.view_height = h;
        self.estimate();
        try self.placeView(h);
        if (self.reveal) {
            self.reveal = false;
            var c = try self.caretAt(self.sel_caret, self.compose_caret, self.affinity);
            if (c.y < self.scroll) {
                self.setScroll(c.y);
            } else if (c.y + c.h > self.scroll + h) {
                // Lay out what is above the caret, a view's height, so the
                // heights it stands on are measured.
                const p = self.paraAt(self.sel_caret);
                var q = p;
                var room = c.y + c.h - self.heights.top(p);
                while (q > 0 and room < h) {
                    q -= 1;
                    room += (try self.paraLayout(q)).h;
                }
                c = try self.caretAt(self.sel_caret, self.compose_caret, self.affinity);
                self.setScroll(c.y + c.h - h);
            }
            try self.placeView(h);
        }
        const total = self.heights.top(self.paras.items.len);
        const s = @max(0, @min(self.scroll, total - h));
        if (s != self.scroll) {
            self.setScroll(s);
            try self.placeView(h);
        }
        if (self.laid > max_laid + self.last - self.first) self.forget();
    }

    /// Lays out the paragraphs in view, from the anchor down, keeping the
    /// view where the anchor is.
    fn placeView(self: *Editor, h: f32) !void {
        const n = self.paras.items.len;
        self.anchor_para = @min(self.anchor_para, n - 1);
        _ = try self.paraLayout(self.anchor_para);
        self.first = self.anchor_para;
        while (self.first > 0 and self.heights.top(self.anchor_para) + self.anchor_offset - self.heights.top(self.first) < 0) {
            self.first -= 1;
            _ = try self.paraLayout(self.first);
        }
        self.setScroll(@max(0, self.heights.top(self.anchor_para) + self.anchor_offset));
        var y = self.heights.top(self.first);
        var p = self.first;
        while (p < n) : (p += 1) {
            y += (try self.paraLayout(p)).h;
            if (y >= self.scroll + h) break;
        }
        self.last = @min(p, n - 1);
    }

    /// Drops the layouts of paragraphs far from view, keeping their heights.
    fn forget(self: *Editor) void {
        const lo = self.first -| max_laid / 4;
        const hi = self.last + max_laid / 4;
        for (self.paras.items, 0..) |*p, i| {
            if ((i < lo or i > hi) and p.laid) {
                p.layout.deinit();
                p.layout = Layout.init(self.allocator);
                p.laid = false;
                self.laid -= 1;
            }
        }
    }

    /// Syncs and lays out for the bounds last placed, as the posted task
    /// does; tests and hosts without a window call it directly.
    pub fn layoutNow(self: *Editor) !void {
        try self.sync();
        const w = @max(self.bounds.width - 2 * self.pad_x, 1);
        const h = @max(self.bounds.height - 2 * self.pad_y, 1);
        try self.layoutView(w, h);
        try self.updateValue();
        // Where the input method's candidates go.
        if (self.paras.items.len > 0) {
            const c = try self.caretAt(self.sel_caret, self.compose_caret, self.affinity);
            self.caret_rect = .{ .x = self.bounds.x + self.pad_x + c.x, .y = self.bounds.y + self.pad_y + @as(f32, @floatCast(c.y - self.scroll)), .width = 1, .height = c.h };
        }
    }

    fn contentPoint(self: *const Editor, point: z.Point) struct { x: f32, y: f64 } {
        return .{ .x = point.x - self.bounds.x - self.pad_x, .y = @as(f64, point.y - self.bounds.y - self.pad_y) + self.scroll };
    }

    fn selection(self: *const Editor) [2]u32 {
        return .{ @min(self.sel_anchor, self.sel_caret), @max(self.sel_anchor, self.sel_caret) };
    }

    // ---- Leaf ------------------------------------------------------------

    fn measure(ptr: *anyopaque, theme: ui.Theme) view.layout.Measurement {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (!std.meta.eql(self.window_theme, theme)) {
            self.window_theme = theme;
            self.look = resolve(self.options.theme, theme);
            self.setPadding();
        }
        const line = @ceil(self.options.font.size * 1.3);
        return .{
            .minimum = .{ .width = 2 * self.pad_x + 4 * line, .height = 2 * self.pad_y + line },
            .preferred = .{ .width = self.options.width, .height = self.options.height },
        };
    }

    fn place(ptr: *anyopaque, id: u64, bounds: Rect) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (self.token != null and self.id != id) self.detach();
        self.id = id;
        const moved = !std.meta.eql(self.bounds, bounds);
        self.bounds = bounds;
        const stale = moved or self.doc.version != self.version or self.doc.selection_version != self.selection_version or self.reveal or self.token == null or
            (self.client != null and !std.meta.eql(self.caret_rect, self.caret_sent)) or self.laid_look == null or !std.meta.eql(self.laid_look.?, self.lookKey());
        if (self.queued or !stale) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = runTask }) catch |err| return self.fail(err);
        self.queued = true;
    }

    /// Posted after paint: lay out, register for input, place the input
    /// method's caret.
    fn runTask(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.id == 0) return;
        const window = self.host.context.window orelse return;
        const before = .{ self.version, self.selection_version, self.scroll, self.first, self.last };
        self.layoutNow() catch |err| self.fail(err);
        if (!std.meta.eql(before, .{ self.version, self.selection_version, self.scroll, self.first, self.last })) window.invalidate();
        if (self.token == null) {
            if (self.host.context.registerTextField(self.id, .{ .context = self, .focus = focusCallback, .blur = blurCallback, .input = inputCallback, .action = actionCallback })) |token| {
                self.token = token;
                window.invalidate();
            } else |err| self.fail(err);
        }
        if (self.client != null and !std.meta.eql(self.caret_sent, self.caret_rect)) {
            if (self.caret_rect) |rect| window.setTextCaret(rect) catch |err| self.fail(err);
            self.caret_sent = self.caret_rect;
        }
        window.invalidate();
    }

    fn status(ptr: *anyopaque) view.EmbedStatus {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        return .{ .composing = self.compose.items.len > 0, .empty = self.doc.text.len() == 0 and self.compose.items.len == 0 };
    }

    fn updateValue(self: *Editor) !void {
        if (self.value_version == self.doc.version and self.value.items.len > 0) return;
        self.value_version = self.doc.version;
        self.value.clearRetainingCapacity();
        var w: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.value);
        defer self.value = w.toArrayList();
        self.text().writeString(&w.writer) catch return error.OutOfMemory;
        if (self.value.items.len > max_value) {
            var cut: usize = max_value;
            while (cut > 0 and self.value.items[cut] & 0xc0 == 0x80) cut -= 1;
            self.value.shrinkRetainingCapacity(cut);
        }
    }

    /// The byte of rune i in the accessibility value, bounded by it.
    fn valueByte(self: *const Editor, i: u32) usize {
        return @min(rt.byteOfRune(self.value.items, i), self.value.items.len);
    }

    // ---- Paint -----------------------------------------------------------

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: Rect) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const focused = self.token != null and frame.context.input_state.focused == id;
        if (focused != self.focused) {
            self.focused = focused;
            self.blink_start = self.now;
            if (!focused) {
                self.dragging = false;
                self.thumb = false;
            }
        }
        const theme = frame.currentTheme();
        if (self.options.frame) {
            frame.roundedRect(bounds, 4, ui.Color.rgb(if (focused) theme.palette.focus else theme.palette.border));
            frame.roundedRect(.{ .x = bounds.x + 1, .y = bounds.y + 1, .width = @max(0, bounds.width - 2), .height = @max(0, bounds.height - 2) }, 3, ui.Color.rgb(theme.palette.inset));
        }
        if (self.token) |token| try frame.textField(token, bounds, true);
        try frame.semantic(.{ .id = id, .role = .text_box, .name = self.options.name, .value = self.value.items, .bounds = bounds, .focused = focused, .read_only = self.options.read_only or self.token == null, .selection_start = self.valueByte(self.selection()[0]), .selection_end = self.valueByte(self.selection()[1]) });
        if (self.paras.items.len == 0 or self.laid_look == null) return;
        try frame.pushClip(bounds);
        defer frame.popClip() catch {};
        try self.paintText(frame, bounds, focused);
    }

    fn paintText(self: *Editor, frame: *ui.Frame, bounds: Rect, focused: bool) !void {
        const look = &self.look;
        const ox = bounds.x + self.pad_x;
        const oy = bounds.y + self.pad_y;
        const w = self.width;
        if (self.textLen() == 0 and self.compose.items.len == 0 and self.options.placeholder.len > 0) {
            const font = self.paraFont(self.paras.items[0].style);
            const line = self.options.measurer.textSize(self.options.placeholder, font);
            const pv = &self.paras.items[0];
            const o = self.origin(0);
            const x = if (pv.laid and pv.layout.lines.items.len > 0) pv.layout.lines.items[0].x else 0;
            frame.labelFont(.{ .x = ox + o.x + x, .y = oy + @as(f32, @floatCast(o.y - self.scroll)), .width = line.width + font.size, .height = line.height }, self.options.placeholder, look.muted, font);
        }
        const sel = self.selection();
        const a = sel[0];
        const b = sel[1];
        var i = self.first;
        while (i <= self.last and i < self.paras.items.len) : (i += 1) {
            const pv = &self.paras.items[i];
            if (!pv.laid) continue;
            const st = pv.style;
            const top = oy + @as(f32, @floatCast(self.heights.top(i) - self.scroll));
            const o = self.origin(i);
            const x = ox + o.x;
            const y = oy + @as(f32, @floatCast(o.y - self.scroll));
            self.paintBlock(frame, i, st, ox, top, pv.h, w);
            const ps = pv.start;
            const pe = ps + pv.n;
            if (a != b and a <= pe and b >= ps and (focused or self.options.read_only)) {
                const from = self.local(i, @max(a, ps));
                const to = self.local(i, @min(b, pe));
                for (0..pv.layout.lines.items.len) |k| {
                    if (pv.layout.selectionRect(@intCast(k), from, to)) |r| {
                        if (r.width > 0) frame.roundedRect(.{ .x = x + r.x, .y = y + r.y, .width = r.width, .height = r.height }, 0, look.selection);
                    }
                }
                if (b > pe and i + 1 < self.paras.items.len) {
                    // The newline selected, as a space after the line.
                    const c = pv.layout.caret(pv.layout.runeCount(), .upstream);
                    frame.roundedRect(.{ .x = x + c.x, .y = y + c.y, .width = self.options.font.size * 0.35, .height = c.height }, 0, look.selection);
                }
            }
            self.paintRuns(frame, &pv.layout, x, y);
            try self.paintAttachments(frame, i, pv, x, y);
            self.paintMarker(frame, i, st, pv, x, y);
            if (self.compose.items.len > 0 and self.paraAt(self.sel_caret) == i) {
                const c = self.local(i, self.sel_caret);
                for (0..pv.layout.lines.items.len) |k| {
                    if (pv.layout.selectionRect(@intCast(k), c, c + self.compose_runes)) |r| frame.rect(.{ .x = x + r.x, .y = y + r.y + r.height - 2, .width = r.width, .height = 1 }, look.text);
                }
            }
        }
        if (focused and !self.options.read_only and a == b) {
            const phase = self.now -| self.blink_start;
            if ((phase / blink_ns) % 2 == 0) {
                const p = self.paraAt(self.sel_caret);
                const pv = &self.paras.items[p];
                if (pv.laid) {
                    const l = @min(self.local(p, self.sel_caret) + self.compose_caret, pv.layout.runeCount());
                    const c = pv.layout.caret(l, self.affinity);
                    const o = self.origin(p);
                    const scale = frame.size.scale;
                    frame.rect(.{ .x = ox + o.x + c.x, .y = oy + @as(f32, @floatCast(o.y + c.y - self.scroll)), .width = @max(1 / scale, 1), .height = c.height }, look.caret);
                }
            }
        }
        const total = self.heights.top(self.paras.items.len);
        if (total > self.view_height) {
            const box = self.thumbBox();
            frame.roundedRect(.{ .x = bounds.x + bounds.width - 8, .y = bounds.y + box[0], .width = 5, .height = box[1] }, 2.5, alpha(look.text, 0.3));
        }
    }

    /// The runs of a layout at (x, y): backgrounds, text and lines.
    fn paintRuns(self: *const Editor, frame: *ui.Frame, l: *const Layout, x: f32, y: f32) void {
        const base = self.look.text;
        for (l.pieces.items) |p| {
            const s = l.styleOf(p);
            const bg = s.background orelse continue;
            if (s.object != null) continue;
            const line = l.lines.items[p.line];
            const width = l.options.measurer.textSize(l.visibleText(p), s.font).width;
            if (s.radius > 0) {
                const size = s.font.size;
                const pad = @min(size * 0.22, s.radius);
                const baseline = y + line.y + line.baseline - s.baseline_shift;
                frame.roundedRect(.{ .x = x + line.x + p.x - pad, .y = baseline - size * 0.98, .width = width + 2 * pad, .height = size * 1.32 }, s.radius, bg);
            } else frame.roundedRect(.{ .x = x + line.x + p.x, .y = y + line.y, .width = p.width, .height = line.height }, 0, bg);
        }
        for (l.pieces.items) |p| {
            const s = l.styleOf(p);
            if (s.object != null) continue;
            const line = l.lines.items[p.line];
            const m = l.fontMetrics(p.span);
            const color = s.color orelse base;
            const t = l.visibleText(p);
            var width = if (t.len > 0) l.options.measurer.textSize(t, s.font).width else 0;
            const baseline = y + line.y + line.baseline - s.baseline_shift;
            const top = baseline - m.ascent;
            if (t.len > 0) frame.labelFont(.{ .x = x + line.x + p.x, .y = top, .width = width + m.size, .height = m.height }, t, color, s.font);
            if (p.hyphen) {
                // The soft hyphen the line breaks at.
                const hyphen = l.hyphenWidth(p.span);
                frame.labelFont(.{ .x = x + line.x + p.x + width, .y = top, .width = hyphen + m.size, .height = m.height }, "-", color, s.font);
                width += hyphen;
            }
            if (!(s.underline or s.strikethrough) or width <= 0) continue;
            const thickness = @max(1, @round(m.size / 14));
            if (s.underline) frame.rect(.{ .x = x + line.x + p.x, .y = baseline + @max(1, m.size * 0.08), .width = width, .height = thickness }, color);
            if (s.strikethrough) frame.rect(.{ .x = x + line.x + p.x, .y = baseline - m.size * 0.3 - thickness / 2, .width = width, .height = thickness }, color);
        }
    }

    /// What a paragraph shows behind its text: the background of a block
    /// of code, the bar of a quotation.
    fn paintBlock(self: *const Editor, frame: *ui.Frame, i: usize, st: ParagraphStyle, x: f32, top: f32, height: f32, width: f32) void {
        const look = &self.look;
        const indent = @as(f32, @floatFromInt(st.indent)) * self.indentWidth();
        if (st.code_block) {
            // One block for the paragraphs of code next to each other,
            // rounded at its ends.
            const radius = self.options.font.size * look.code_block_radius;
            const first = i == 0 or !self.paras.items[i - 1].style.code_block;
            const last = i + 1 >= self.paras.items.len or !self.paras.items[i + 1].style.code_block;
            const box: Rect = .{ .x = x + indent, .y = top, .width = @max(0, width - indent), .height = height };
            if (first and last) {
                frame.roundedRect(box, radius, look.code_block_background);
            } else if (first or last) {
                // Rounded at one end: a rounded box and a square half.
                frame.roundedRect(box, radius, look.code_block_background);
                const half: Rect = if (first) .{ .x = box.x, .y = box.y + box.height / 2, .width = box.width, .height = box.height / 2 } else .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height / 2 };
                frame.roundedRect(half, 0, look.code_block_background);
            } else frame.roundedRect(box, 0, look.code_block_background);
        }
        if (st.quote) {
            const w = look.quote_bar_width;
            frame.roundedRect(.{ .x = x + indent, .y = top, .width = w, .height = height }, w / 2, ui.Color.rgb(look.quote_bar));
        }
    }

    /// The marker of an item of a list: its bullet, its number, or its
    /// check box.
    fn paintMarker(self: *Editor, frame: *ui.Frame, i: usize, st: ParagraphStyle, pv: *ParaView, x: f32, y: f32) void {
        if (st.list == .none) return;
        const look = &self.look;
        const line = pv.layout.caret(0, .downstream);
        const font = self.paraFont(st);
        const indent = self.indentWidth();
        if (st.list == .tasks) {
            const box = font.size * 0.95;
            const bx = x - indent + (indent - box) / 2 - indent * 0.1;
            const by = y + line.y + (line.height - box) / 2;
            const r: Rect = .{ .x = bx, .y = by, .width = box, .height = box };
            if (st.checked) {
                frame.roundedRect(r, box * 0.25, ui.Color.rgb(look.checkbox));
                const check: view.Font = .{ .size = box * 0.8, .weight = .bold };
                const m = self.options.measurer.textSize("\u{2713}", check);
                frame.labelFont(.{ .x = bx + (box - m.width) / 2, .y = by + (box - m.height) / 2, .width = m.width + box, .height = m.height }, "\u{2713}", look.checkmark, check);
            } else frame.strokeRect(r, box * 0.25, 1.25, ui.Color.rgb(look.muted));
            return;
        }
        if (pv.marker_len == 0) {
            const mark = self.marker(i, st, &pv.marker);
            pv.marker_len = @intCast(mark.len);
        }
        const mark = pv.marker[0..pv.marker_len];
        const m = self.options.measurer.textSize(mark, font);
        var mx = x - m.width - indent * 0.25;
        if (st.list == .bullets) mx = x - indent * 0.5 - m.width / 2;
        const first = if (pv.layout.lines.items.len > 0) pv.layout.lines.items[0] else return;
        const metrics = self.options.measurer.textSize("Ag", font).height;
        const ascent = metrics / 2 + font.size * 0.35;
        frame.labelFont(.{ .x = mx, .y = y + first.y + first.baseline - ascent, .width = m.width + font.size, .height = metrics }, mark, look.marker, font);
    }

    /// The number of the item of a numbered list paragraph p is: one more
    /// than the item of the same level before it, deeper ones between them
    /// skipped, from 1.
    fn listNumber(self: *Editor, p: usize) u32 {
        if (self.numbers_version != self.version) {
            self.numbers.clearRetainingCapacity();
            self.numbers_version = self.version;
        }
        if (self.numbers.get(p)) |n| return n;
        const st = self.paras.items[p].style;
        var n: u32 = 1;
        var q = p;
        while (q > 0) {
            q -= 1;
            const qs = self.paras.items[q].style;
            if (qs.list == .none or qs.indent < st.indent) break;
            if (qs.indent > st.indent) continue;
            if (qs.list == .numbers) n = self.listNumber(q) + 1;
            break;
        }
        self.numbers.put(self.allocator, p, n) catch {};
        return n;
    }

    /// What marks item p of a list: a bullet for its level, or its number
    /// in digits, letters or Roman numerals by level.
    fn marker(self: *Editor, p: usize, st: ParagraphStyle, out: []u8) []const u8 {
        switch (st.list) {
            .bullets => return std.fmt.bufPrint(out, "{s}", .{([_][]const u8{ "\u{2022}", "\u{25e6}", "\u{25aa}" })[st.indent % 3]}) catch "",
            .numbers => {
                const n = self.listNumber(p);
                var buffer: [20]u8 = undefined;
                const digits = switch (st.indent % 3) {
                    1 => alphaNumber(n, &buffer),
                    2 => romanNumber(n, &buffer),
                    else => std.fmt.bufPrint(&buffer, "{d}", .{n}) catch "",
                };
                return std.fmt.bufPrint(out, "{s}.", .{digits}) catch "";
            },
            else => return "",
        }
    }

    /// The attachments of paragraph i in the boxes its layout keeps.
    fn paintAttachments(self: *const Editor, frame: *ui.Frame, i: usize, pv: *const ParaView, x: f32, y: f32) !void {
        for (pv.layout.pieces.items) |p| {
            const r = pv.layout.objectRect(p) orelse continue;
            const g = self.global(i, p.rune);
            if (self.compose.items.len > 0 and self.paraAt(self.sel_caret) == i) {
                const c = self.sel_caret - pv.start;
                if (p.rune >= c and p.rune < c + self.compose_runes) continue;
            }
            const at = self.text().attributesAt(g).attachment orelse continue;
            const box: Rect = .{ .x = x + r.x, .y = y + r.y, .width = r.width, .height = r.height };
            if (self.options.attachment_painter) |painter| {
                try painter.paint(painter.context, frame, at, box);
                continue;
            }
            // Not drawn: a box with its name.
            frame.roundedRect(box, 4, self.look.code_block_background);
            frame.strokeRect(box, 4, 1, ui.Color.rgb(self.look.border));
            if (at.name.len > 0) {
                const font: view.Font = .{ .size = self.options.font.size * 0.85 };
                const m = self.options.measurer.textSize(at.name, font);
                try frame.pushClip(box);
                frame.labelFont(.{ .x = box.x + 4, .y = box.y + (box.height - m.height) / 2, .width = @max(box.width - 8, 1), .height = m.height }, at.name, self.look.muted, font);
                try frame.popClip();
            }
        }
    }

    /// The top and height of the scroll bar's thumb, in the leaf.
    fn thumbBox(self: *const Editor) [2]f32 {
        const total = self.heights.top(self.paras.items.len);
        const track = self.bounds.height - 4;
        const size = @max(24, track * @as(f32, @floatCast(@as(f64, self.view_height) / @max(total, 1))));
        const room: f64 = track - size;
        var at: f64 = 0;
        const most = total - self.view_height;
        if (most > 0) at = self.scroll / most;
        return .{ 2 + @as(f32, @floatCast(room * at)), size };
    }

    fn overScrollbar(self: *const Editor, x: f32) bool {
        return self.heights.top(self.paras.items.len) > self.view_height and x - self.bounds.x >= self.bounds.width - scrollbar_width;
    }

    fn dragThumb(self: *Editor, y_window: f32) void {
        const y = y_window - self.bounds.y;
        const box = self.thumbBox();
        const track = self.bounds.height - 4 - box[1];
        const total = self.heights.top(self.paras.items.len) - self.view_height;
        if (track <= 0 or total <= 0) return;
        const f: f64 = (y - self.thumb_grab - 2) / track;
        self.setScroll(std.math.clamp(f, 0, 1) * total);
    }

    // ---- Input -----------------------------------------------------------

    fn textClient(self: *Editor) z.TextClient {
        return .{ .context = self, .owner = self.host.context.window.?.app.owner, .read = clientRead, .change = clientChange, .unbound = clientUnbound };
    }

    fn focusCallback(ptr: *anyopaque, scope: *ui.TextFieldScope) anyerror!z.TextClientToken {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const window = scope.window();
        const token = try window.setTextClient(self.textClient());
        self.client = token;
        self.caret_sent = null;
        self.blink_start = self.now;
        return token;
    }
    fn blurCallback(ptr: *anyopaque, window: z.Window) anyerror!void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (self.client) |client| _ = try window.clearTextClient(client);
        self.client = null;
        self.commitCompose() catch |err| self.fail(err);
        self.dragging = false;
        self.thumb = false;
    }
    fn actionCallback(ptr: *anyopaque, _: *ui.TextFieldScope, action: ui.TextFieldAction) anyerror!ui.TextFieldResult {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        try self.sync();
        switch (action) {
            .set_value => |value| {
                if (self.options.read_only) return .{};
                self.sel_anchor = 0;
                self.sel_caret = self.textLen();
                self.publish();
                try self.insert(value);
            },
            .select_text => |r| {
                const a = self.runeOfUnits(r.start_utf16);
                const b = self.runeOfUnits(r.end_utf16);
                self.moveSelection(a, b);
            },
            .undo => try self.takeBack(false),
            .redo => try self.takeBack(true),
        }
        self.afterInput();
        return .{ .handled = true };
    }
    fn inputCallback(ptr: *anyopaque, _: *ui.TextFieldScope, event: z.Event) anyerror!ui.TextFieldResult {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        const handled = self.handle(event);
        return .{ .handled = handled };
    }

    /// Pointer hover outside the text field route: the cursor's shape.
    fn hoverInput(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_move => |local_point| {
                const before = self.cursor;
                self.hover(.{ .x = self.bounds.x + local_point.x, .y = self.bounds.y + local_point.y }) catch |err| self.fail(err);
                return before != self.cursor;
            },
            else => return false,
        }
    }

    /// One input event for the focused editor; true when it was used.
    pub fn handle(self: *Editor, event: z.Event) bool {
        const handled = self.handleEvent(event) catch |err| {
            self.fail(err);
            return true;
        };
        if (handled) self.afterInput();
        return handled;
    }

    fn afterInput(self: *Editor) void {
        self.layoutNow() catch |err| self.fail(err);
        if (self.changed) if (self.options.on_change) |callback| callback.call(callback.context, self);
        self.invalidate();
        if (self.client != null and !std.meta.eql(self.caret_rect, self.caret_sent)) {
            if (self.host.context.window) |window| {
                if (self.caret_rect) |rect| window.setTextCaret(rect) catch |err| self.fail(err);
                self.caret_sent = self.caret_rect;
            }
        }
    }

    fn handleEvent(self: *Editor, event: z.Event) !bool {
        try self.sync();
        if (self.paras.items.len == 0) return false;
        switch (event) {
            .key_input => |k| {
                if (try self.key(k.key, k.modifiers)) {
                    self.blink_start = self.now;
                    return true;
                }
                return false;
            },
            .edit_key => |e| return self.key(switch (e.key) {
                inline else => |k| @field(z.KeyCode, @tagName(k)),
            }, .{ .control = e.control, .shift = e.shift }),
            .text_input => |t| {
                if (self.options.read_only or t.text.len == 0) return false;
                try self.replaceText(null, t.text);
                self.blink_start = self.now;
                return true;
            },
            .text_preedit => |m| {
                if (self.options.read_only) return false;
                try self.setMarkedText(m.text, m.selection_start, m.selection_end);
                return true;
            },
            .text_preedit_cancel => {
                if (self.compose.items.len > 0) self.compose_revision += 1;
                self.compose.clearRetainingCapacity();
                self.compose_runes = 0;
                self.compose_caret = 0;
                self.reveal = true;
                return true;
            },
            .pointer_down => |down| return self.press(down),
            .pointer_move => |point| return self.move(point),
            .pointer_up => return self.release(),
            .wheel => |w| {
                const before = self.scroll;
                const total = self.heights.top(self.paras.items.len);
                self.setScroll(@max(0, @min(self.scroll + w.delta.y, total - self.view_height)));
                // At an end, the wheel goes on to the containers around.
                return self.scroll != before;
            },
            else => return false,
        }
    }

    /// Gives the document the editor's selection.
    fn publish(self: *Editor) void {
        self.doc.moveSelection(self.sel_anchor, self.sel_caret);
    }

    fn moveSelection(self: *Editor, anchor: u32, caret: u32) void {
        const n = self.textLen();
        self.sel_anchor = @min(anchor, n);
        self.sel_caret = @min(caret, n);
        self.affinity = .downstream;
        self.reveal = true;
        self.publish();
    }

    /// Puts the caret at i, extending the selection or not.
    fn moveTo(self: *Editor, i: u32, affinity: Affinity, extend: bool) void {
        const c = @min(i, self.textLen());
        self.sel_caret = c;
        self.affinity = affinity;
        if (!extend) self.sel_anchor = c;
        self.coalesce = false;
        self.reveal = true;
        self.publish();
    }

    fn runeAt(self: *const Editor, i: u32) u21 {
        return self.text().runeAt(i);
    }

    /// The end of the word after `from`, skipping what is between: each
    /// ideograph and kana is a word (see `rt.words`).
    fn nextWord(self: *const Editor, from: u32) u32 {
        const n = self.textLen();
        var i = from;
        while (i < n and !isWord(self.runeAt(i))) i += 1;
        if (i < n) {
            i += 1;
            while (i < n and !rt.words.boundary(self.runeAt(i - 1), self.runeAt(i))) i += 1;
        }
        return i;
    }

    /// The start of the word before `from`.
    fn prevWord(self: *const Editor, from: u32) u32 {
        var i = from;
        while (i > 0 and !isWord(self.runeAt(i - 1))) i -= 1;
        if (i > 0) {
            i -= 1;
            while (i > 0 and !rt.words.boundary(self.runeAt(i - 1), self.runeAt(i))) i -= 1;
        }
        return i;
    }

    /// The word, or the run of other runes, around i, within its
    /// paragraph: an ideograph or a kana is a word alone.
    fn wordAt(self: *const Editor, i_: u32) [2]u32 {
        const n = self.textLen();
        if (n == 0) return .{ 0, 0 };
        const i = @min(i_, n - 1);
        var a = i;
        var b = i;
        while (a > 0) {
            const r = self.runeAt(a - 1);
            if (r == '\n' or rt.words.boundary(r, self.runeAt(a))) break;
            a -= 1;
        }
        if (self.runeAt(i) != '\n') {
            b = i + 1;
            while (b < n) {
                const r = self.runeAt(b);
                if (r == '\n' or rt.words.boundary(self.runeAt(b - 1), r)) break;
                b += 1;
            }
        }
        return .{ a, b };
    }

    /// The edge of the grapheme before i (dir < 0) or after it: a newline
    /// is one.
    fn grapheme(self: *Editor, i: u32, dir: i32) !u32 {
        const n = self.textLen();
        const p = self.paraAt(i);
        const ps = self.paras.items[p].start;
        const pe = self.paraEnd(p);
        if (dir < 0 and i == ps) return i -| 1;
        if (dir > 0 and i >= pe) return @min(i + 1, n);
        const pv = try self.paraLayout(p);
        const l = self.local(p, i);
        return self.global(p, if (dir < 0) pv.layout.previousBoundary(l) else pv.layout.nextBoundary(l));
    }

    /// The caret one grapheme left (dir < 0) or right, and to the next
    /// paragraph at the edge of one.
    fn visual(self: *Editor, dir: i32) !struct { i: u32, affinity: Affinity } {
        const p = self.paraAt(self.sel_caret);
        const pv = try self.paraLayout(p);
        const l = self.local(p, self.sel_caret);
        if (dir < 0) {
            if (l == 0) return .{ .i = self.paras.items[p].start -| 1, .affinity = .downstream };
            const to = pv.layout.previousBoundary(l);
            return .{ .i = self.global(p, to), .affinity = .downstream };
        }
        if (l >= pv.layout.runeCount()) return .{ .i = @min(self.paraEnd(p) + 1, self.textLen()), .affinity = .downstream };
        const to = pv.layout.nextBoundary(l);
        // Moving onto the end of a wrapped line stays on it.
        const k = pv.layout.lineOf(l, self.affinity);
        const line = pv.layout.lines.items[k];
        const aff: Affinity = if (to == line.end and k + 1 < pv.layout.lines.items.len) .upstream else .downstream;
        return .{ .i = self.global(p, to), .affinity = aff };
    }

    /// Moves the caret up or down lines, keeping its x.
    fn vertical(self: *Editor, lines: i32, extend: bool) !void {
        const c = try self.caretAt(self.sel_caret, 0, self.affinity);
        const x = self.desired_x orelse c.x;
        const target = c.y + c.h / 2 + @as(f64, @floatFromInt(lines)) * c.h;
        if (target < 0) {
            self.moveTo(0, .downstream, extend);
        } else if (target > self.heights.top(self.paras.items.len)) {
            self.moveTo(self.textLen(), .downstream, extend);
        } else {
            const at = try self.positionAt(x, target);
            self.moveTo(at.i, at.affinity, extend);
        }
        self.desired_x = x;
    }

    /// Handles a key pressed, and reports whether it took it.
    fn key(self: *Editor, k: z.KeyCode, mods: z.KeyModifiers) !bool {
        if (shortcut(k, mods)) |cmd| return self.run(cmd);
        const shift = mods.shift;
        var m = mods;
        m.shift = false;
        const none = !m.control and !m.alt and !m.super;
        const ctrl = m.control and !m.alt and !m.super;
        if (k == .v and shift and m.control and !m.super) return self.run(.paste_and_match_style);
        const sel = self.selection();
        const a = sel[0];
        const b = sel[1];
        const n = self.textLen();
        switch (k) {
            .left, .right => {
                const left = k == .left;
                if (m.alt and !m.control) return false; // back and forward
                if (ctrl and left) {
                    self.moveTo(self.prevWord(self.sel_caret), .downstream, shift);
                } else if (ctrl) {
                    self.moveTo(self.nextWord(self.sel_caret), .downstream, shift);
                } else if (!none) {
                    return false;
                } else if (a != b and !shift) {
                    self.moveTo(if (left) a else b, .downstream, false);
                } else {
                    const to = try self.visual(if (left) -1 else 1);
                    self.moveTo(to.i, to.affinity, shift);
                }
                self.desired_x = null;
                return true;
            },
            .up, .down => {
                if (ctrl) {
                    // By paragraphs: up to the start of this one or the one
                    // before, down to the start of the next, as WordPad and
                    // GTK.
                    const r = self.text().paragraphRange(self.sel_caret);
                    if (k == .up and self.sel_caret == r.start and r.start > 0) {
                        self.moveTo(self.text().paragraphRange(r.start - 1).start, .downstream, shift);
                    } else if (k == .up) {
                        self.moveTo(r.start, .downstream, shift);
                    } else self.moveTo(@min(r.end + 1, n), .downstream, shift);
                    self.desired_x = null;
                    return true;
                }
                if (!none) return false;
                try self.vertical(if (k == .up) -1 else 1, shift);
                return true;
            },
            .page_up, .page_down => {
                var lines: i32 = @max(@as(i32, @intFromFloat(self.view_height / (self.options.font.size * 1.3))) - 1, 1);
                if (k == .page_up) lines = -lines;
                try self.vertical(lines, shift);
                return true;
            },
            .home, .end => {
                if (ctrl) {
                    self.moveTo(if (k == .home) 0 else n, .downstream, shift);
                    return true;
                }
                const edges = try self.lineEdges(self.sel_caret);
                if (k == .home) self.moveTo(edges[0], .downstream, shift) else self.moveTo(edges[1], .upstream, shift);
                return true;
            },
            .a => if (ctrl) {
                self.moveSelectionKeep(0, n);
                return true;
            },
            .c => if (ctrl) return self.run(.copy),
            .x => if (ctrl) return self.run(.cut),
            .v => if (ctrl) return self.run(.paste),
            .z => if (ctrl) return self.run(if (shift) .redo else .undo),
            .y => if (ctrl) return self.run(.redo),
            .insert => {
                if (ctrl and !shift) return self.run(.copy);
                if (shift and none) return self.run(.paste);
            },
            else => {},
        }
        if (self.options.read_only) return false;
        const p = self.paraAt(self.sel_caret);
        const st = self.paras.items[p].style;
        const ps = self.paras.items[p].start;
        switch (k) {
            .backspace => {
                if (a != b) {
                    try self.deleteRange(a, b, false);
                } else if (none and self.sel_caret == ps and special(st)) {
                    // At the start of a list's item, a heading, a quotation or
                    // a block of code, Backspace takes the style away before
                    // joining.
                    try self.command(.{ .unstyle = {} });
                } else if (ctrl) {
                    try self.deleteRange(self.prevWord(self.sel_caret), self.sel_caret, false);
                } else if (self.sel_caret > 0) {
                    try self.deleteRange(try self.grapheme(self.sel_caret, -1), self.sel_caret, true);
                }
                return true;
            },
            .delete => {
                if (a != b) {
                    if (shift and none) return self.run(.cut);
                    try self.deleteRange(a, b, false);
                } else if (ctrl) {
                    try self.deleteRange(self.sel_caret, self.nextWord(self.sel_caret), false);
                } else if (self.sel_caret < n) {
                    try self.deleteRange(self.sel_caret, try self.grapheme(self.sel_caret, 1), false);
                }
                return true;
            },
            .enter => {
                if (!none) return false;
                try self.enter();
                return true;
            },
            .tab => {
                if (!none) return false;
                if (st.list != .none) return self.run(if (shift) .outdent else .indent);
                if (st.code_block and !shift) {
                    try self.insert("\t");
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    fn moveSelectionKeep(self: *Editor, anchor: u32, caret: u32) void {
        self.sel_anchor = anchor;
        self.sel_caret = caret;
        self.publish();
    }

    /// Performs a command of a menu or a shortcut, and reports whether the
    /// editor took it.
    pub fn runCommand(self: *Editor, cmd: Command) bool {
        const taken = blk: {
            self.sync() catch |err| {
                self.fail(err);
                break :blk true;
            };
            break :blk self.run(cmd) catch |err| {
                self.fail(err);
                break :blk true;
            };
        };
        if (taken) self.afterInput();
        return taken;
    }

    fn run(self: *Editor, cmd: Command) !bool {
        const sel = self.selection();
        const a = sel[0];
        const b = sel[1];
        switch (cmd) {
            .copy => {
                if (a != b) try self.copySelection();
                return true;
            },
            .cut => {
                if (a != b and !self.options.read_only) {
                    try self.copySelection();
                    try self.deleteRange(a, b, false);
                }
                return true;
            },
            .paste, .paste_and_match_style => {
                if (!self.options.read_only) if (self.options.clipboard) |clipboard| {
                    try clipboard.read(clipboard.context, self, cmd == .paste_and_match_style);
                };
                return true;
            },
            .select_all => {
                self.moveSelectionKeep(0, self.textLen());
                return true;
            },
            .delete => {
                if (a != b and !self.options.read_only) try self.deleteRange(a, b, false);
                return true;
            },
            .undo, .redo => {
                if (!self.options.read_only) {
                    try self.commitCompose();
                    try self.takeBack(cmd == .redo);
                }
                return true;
            },
            .link => {
                if (self.options.read_only) return false;
                if (self.options.on_link_command) |callback| {
                    self.publish();
                    callback.call(callback.context, self);
                    return true;
                }
                if (a == b) return true;
                const s = try self.text().sliceString(self.allocator, a, b);
                defer self.allocator.free(s);
                const url = std.mem.trim(u8, s, " \t\n");
                if (!looksLikeUrl(url)) return true;
                try self.command(.{ .link = url });
                return true;
            },
            else => {},
        }
        if (self.options.read_only) return true;
        try self.command(switch (cmd) {
            .bold => .bold,
            .italic => .italic,
            .underline => .underline,
            .strikethrough => .strikethrough,
            .code => .code,
            .bullets => .{ .list = .bullets },
            .numbers => .{ .list = .numbers },
            .tasks => .{ .list = .tasks },
            .indent => .{ .indent = 1 },
            .outdent => .{ .indent = -1 },
            .align_left => .{ .@"align" = .start },
            .align_center => .{ .@"align" = .center },
            .align_right => .{ .@"align" = .end },
            .quote => .quote,
            .code_block => .code_block,
            .heading => |level| .{ .heading = level },
            else => unreachable,
        });
        return true;
    }

    // ---- Editing ---------------------------------------------------------

    /// A command of the document, run on the editor's selection.
    const DocCommand = union(enum) {
        bold,
        italic,
        underline,
        strikethrough,
        code,
        list: rt.ListKind,
        indent: i32,
        @"align": rt.Align,
        quote,
        code_block,
        heading: u8,
        link: []const u8,
        unstyle,
        exit_block,
        checked: u32,
        undo,
        redo,
    };

    fn command(self: *Editor, cmd: DocCommand) !void {
        self.publish();
        const d = self.doc;
        const before = d.version;
        switch (cmd) {
            .bold => try d.toggleBold(),
            .italic => try d.toggleItalic(),
            .underline => try d.toggleUnderline(),
            .strikethrough => try d.toggleStrikethrough(),
            .code => try d.toggleCode(),
            .list => |kind| try d.toggleList(kind),
            .indent => |levels| try d.indent(levels),
            .@"align" => |value| try d.setAlign(value),
            .quote => try d.toggleQuote(),
            .code_block => try d.toggleCodeBlock(),
            .heading => |level| try d.setHeading(level),
            .link => |url| try d.setLink(url),
            .unstyle => try d.formatParagraphs(Unstyle{}),
            .exit_block => try d.formatParagraphs(ExitBlock{ .after_code = self.paraAt(self.sel_caret) > 0 and self.paras.items[self.paraAt(self.sel_caret) - 1].style.code_block }),
            .checked => |i| try d.toggleChecked(i),
            .undo => try d.undo(),
            .redo => try d.redo(),
        }
        if (d.version != before) self.changed = true;
        try self.sync();
        self.mode = .new;
        self.coalesce = false;
    }

    /// Undoes the document's last step, or redoes the last undone.
    fn takeBack(self: *Editor, redo: bool) !void {
        try self.command(if (redo) .redo else .undo);
        self.reveal = true;
    }

    /// Starts an action of the editor: typing joins the step typing made
    /// last, anything else starts a step of its own.
    fn record(self: *Editor, typing: bool) void {
        self.mode = if (typing and self.coalesce) .typing else .new;
        self.coalesce = typing;
    }

    /// Runs `func(ctx, *Edit)` as an edit of the document in the action's
    /// step, and takes what it changed.
    fn editWith(self: *Editor, ctx: anytype, comptime func: anytype) !void {
        const d = self.doc;
        const before = d.version;
        switch (self.mode) {
            .same => try d.editStep(if (d.undo_steps.items.len > 0) .same else .new, ctx, func),
            else => {
                try d.editStep(if (self.mode == .typing) .typing else .new, ctx, func);
                // Typing that starts a step lets the typing after it join it.
                d.coalesce = self.coalesce;
            },
        }
        self.mode = .same;
        if (d.version != before) {
            self.changed = true;
            self.selection_version = d.selection_version;
            try self.sync();
        }
    }

    const ReplaceString = struct {
        start: u32,
        end: u32,
        s: []const u8,
        attrs: Attributes,
        fn run(c: @This(), e: *rt.Edit) !void {
            try e.replaceString(c.start, c.end, c.s, c.attrs);
        }
    };

    /// Replaces the runes from start to end with s in the typing
    /// attributes, as part of the action's step, and puts the caret after.
    fn replace(self: *Editor, start: u32, end: u32, s: []const u8) !void {
        self.publish();
        const d = self.doc;
        const attrs = d.typing orelse rt.typingAttributesOf(&d.text, start, end);
        // The step keeps the text it replaces; the attributes are interned
        // in the text, which they outlive.
        try self.editWith(ReplaceString{ .start = start, .end = end, .s = s, .attrs = attrs }, ReplaceString.run);
        const caret = start + rt.runeCount(s);
        self.sel_anchor = caret;
        self.sel_caret = caret;
        d.anchor = caret;
        d.caret = caret;
        if (s.len == 0 and start < end) {
            // Typing again where text was deleted gets its attributes,
            // until the caret moves.
            try d.setTypingAttributes(attrs);
        }
        self.affinity = .downstream;
        self.desired_x = null;
        self.reveal = true;
    }

    /// Replaces the selection with s, as typing does.
    fn insert(self: *Editor, s_: []const u8) !void {
        if (self.options.read_only) return;
        const s = try normalizeNewlines(self.allocator, s_);
        defer if (s.ptr != s_.ptr) self.allocator.free(s);
        const sel = self.selection();
        self.record(sel[0] == sel[1] and rt.runeCount(s) == 1 and !std.mem.eql(u8, s, "\n"));
        try self.replace(sel[0], sel[1], s);
    }

    /// Deletes the runes from a to b.
    fn deleteRange(self: *Editor, a: u32, b: u32, typing: bool) !void {
        if (a == b or self.options.read_only) return;
        self.record(typing);
        try self.replace(@min(a, b), @max(a, b), "");
    }

    /// Makes the next edit join the step of the edit before it, unless the
    /// action started a step no edit made yet: a composition at a caret
    /// starts one that its commit makes.
    fn joinStep(self: *Editor) void {
        if (self.mode != .new) self.mode = .same;
    }

    /// Puts the composition into the text, in the typing attributes, as
    /// part of the step its start made.
    fn commitCompose(self: *Editor) !void {
        if (self.compose.items.len > 0) {
            const s = try self.allocator.dupe(u8, self.compose.items);
            defer self.allocator.free(s);
            self.compose.clearRetainingCapacity();
            self.compose_runes = 0;
            self.compose_revision += 1;
            self.joinStep();
            try self.replace(self.sel_caret, self.sel_caret, s);
        }
        self.compose_caret = 0;
        self.composing = false;
    }

    /// Text an input method or the keyboard committed, over `range` of
    /// runes or the composition and the selection.
    fn replaceText(self: *Editor, range: ?[2]u32, s: []const u8) !void {
        if (range) |r| {
            const transaction = self.composing;
            try self.commitCompose();
            if (!transaction) self.record(false) else self.joinStep();
            try self.replace(@min(r[0], r[1]), @max(r[0], r[1]), s);
        } else if (self.compose.items.len > 0) {
            self.dropComposeText();
            self.joinStep();
            try self.replace(self.sel_caret, self.sel_caret, s);
        } else {
            try self.insert(s);
            try self.typed(s);
        }
        self.dropComposeText();
        self.composing = false;
        self.reveal = true;
    }

    fn dropComposeText(self: *Editor) void {
        if (self.compose.items.len > 0) self.compose_revision += 1;
        self.compose.clearRetainingCapacity();
        self.compose_runes = 0;
        self.compose_caret = 0;
    }

    /// An input method's composition at the selection; its caret is the
    /// end of `selected`, a byte offset into `s`.
    fn setMarkedText(self: *Editor, s: []const u8, selected_start: usize, selected_end: usize) !void {
        _ = selected_start;
        if (self.compose.items.len == 0) {
            const sel = self.selection();
            const transaction = self.composing and self.compose.items.len > 0;
            if (!transaction) self.record(false) else self.joinStep();
            self.composing = true;
            if (sel[0] != sel[1]) try self.replace(sel[0], sel[1], "");
        }
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        self.compose.clearRetainingCapacity();
        try self.compose.appendSlice(self.allocator, s);
        self.compose_runes = rt.runeCount(s);
        var end = @min(selected_end, s.len);
        while (end > 0 and end < s.len and s[end] & 0xc0 == 0x80) end -= 1;
        self.compose_caret = rt.runeCount(s[0..end]);
        self.compose_revision += 1;
        self.reveal = true;
        if (s.len == 0) self.compose_caret = 0;
    }

    const Unstyle = struct {
        pub fn change(_: Unstyle, s: *ParagraphStyle) void {
            unstyle(s);
        }
    };

    const ExitBlock = struct {
        after_code: bool,
        pub fn change(self: ExitBlock, s: *ParagraphStyle) void {
            _ = exitBlock(s, self.after_code);
        }
    };

    const CodeFence = struct {
        start: u32,
        end: u32,
        fn run(c: @This(), e: *rt.Edit) !void {
            try e.replaceString(c.start, c.end, "", .{});
            try e.formatParagraphs(c.start, c.start, MakeCode{});
            e.select(c.start, c.start);
        }
    };
    const MakeCode = struct {
        pub fn change(_: MakeCode, s: *ParagraphStyle) void {
            s.* = .{ .code_block = true, .indent = s.indent };
        }
    };
    const AfterEnter = struct {
        at: u32,
        at_end: bool,
        fn run(c: @This(), e: *rt.Edit) !void {
            try e.formatParagraphs(c.at, c.at, NewItem{ .at_end = c.at_end });
        }
    };
    const NewItem = struct {
        at_end: bool,
        pub fn change(self: NewItem, s: *ParagraphStyle) void {
            if (self.at_end and s.heading > 0) s.heading = 0;
            s.checked = false;
        }
    };

    /// Breaks the paragraph at the selection: a list's item continues the
    /// list and an empty one leaves it, a heading ends at its end, and
    /// "```" starts a block of code.
    fn enter(self: *Editor) !void {
        const sel = self.selection();
        const a = sel[0];
        const b = sel[1];
        const p = self.paraAt(self.sel_caret);
        const st = self.paras.items[p].style;
        const ps = self.paras.items[p].start;
        const pe = self.paraEnd(p);
        const after_code = p > 0 and self.paras.items[p - 1].style.code_block;
        if (a == b and ps == pe) {
            var probe = st;
            if (exitBlock(&probe, after_code)) {
                try self.command(.exit_block);
                return;
            }
        }
        if (!self.options.no_markdown and a == b and self.sel_caret == pe and !st.code_block) {
            const line = self.text().para(@intCast(p)).text();
            if (std.mem.startsWith(u8, line, "```") and std.mem.indexOfScalar(u8, line[3..], '`') == null) {
                self.publish();
                self.mode = .new;
                try self.editWith(CodeFence{ .start = ps, .end = pe }, CodeFence.run);
                self.mode = .new;
                self.coalesce = false;
                self.sel_anchor = self.doc.anchor;
                self.sel_caret = self.doc.caret;
                self.selection_version = self.doc.selection_version;
                self.reveal = true;
                return;
            }
        }
        const at_end = self.sel_caret == pe and a == b;
        const at_start = a == b and a == ps and ps < pe;
        self.publish();
        const attrs = self.doc.typingAttributes();
        self.record(false);
        try self.replace(a, b, "\n");
        // The new paragraph: after the caret's, or before it at its start,
        // as a checked item moved down stays checked.
        const at = if (at_start) self.sel_caret - 1 else self.sel_caret;
        try self.editWith(AfterEnter{ .at = at, .at_end = at_end }, AfterEnter.run);
        self.doc.anchor = self.sel_caret;
        self.doc.caret = self.sel_caret;
        try self.doc.setTypingAttributes(attrs);
        self.coalesce = false;
    }

    const BlockShortcut = struct {
        ps: u32,
        n: u32,
        set: SetStyle,
        fn run(c: @This(), e: *rt.Edit) !void {
            try e.replaceString(c.ps, c.ps + c.n, "", .{});
            try e.formatParagraphs(c.ps, c.ps, c.set);
            e.select(c.ps, c.ps);
        }
    };
    const SetStyle = struct {
        kind: enum { heading, bullets, tasks, quote, numbers },
        level: u8 = 0,
        checked: bool = false,
        pub fn change(self: SetStyle, s: *ParagraphStyle) void {
            switch (self.kind) {
                .heading => {
                    s.heading = self.level;
                    s.list = .none;
                    s.checked = false;
                },
                .bullets => {
                    s.list = .bullets;
                    s.heading = 0;
                },
                .tasks => {
                    s.list = .tasks;
                    s.heading = 0;
                    s.checked = self.checked;
                },
                .quote => s.quote = true,
                .numbers => {
                    s.list = .numbers;
                    s.heading = 0;
                },
            }
        }
    };

    /// Runs the Markdown shortcuts after s was typed at the caret.
    fn typed(self: *Editor, s: []const u8) !void {
        if (self.options.no_markdown or self.options.read_only or rt.runeCount(s) != 1) return;
        const p = self.paraAt(self.sel_caret);
        const ps = self.paras.items[p].start;
        if (self.paras.items[p].style.code_block) return;
        const line = self.text().para(@intCast(p)).text();
        const before = line[0..rt.byteOfRune(line, self.sel_caret - ps)];
        if (before.len == 0) return;
        if (std.mem.eql(u8, s, " ")) return self.blockShortcut(ps, before[0 .. before.len - 1]);
        if (s.len == 1 and (s[0] == '*' or s[0] == '_' or s[0] == '`' or s[0] == '~')) return self.inlineShortcut(ps, before);
    }

    /// Turns what was typed before a space at the start of a paragraph into
    /// its style: "# " a heading, "- " a list, "> " a quotation.
    fn blockShortcut(self: *Editor, ps: u32, prefix: []const u8) !void {
        var set: ?SetStyle = null;
        if (prefix.len > 0 and prefix.len <= 6 and std.mem.trim(u8, prefix, "#").len == 0) {
            set = .{ .kind = .heading, .level = @intCast(prefix.len) };
        } else if (eqlAny(prefix, &.{ "-", "*", "+" })) {
            set = .{ .kind = .bullets };
        } else if (eqlAny(prefix, &.{ "[]", "[ ]", "- [ ]", "-[ ]" })) {
            set = .{ .kind = .tasks };
        } else if (eqlAny(prefix, &.{ "[x]", "- [x]", "[X]" })) {
            set = .{ .kind = .tasks, .checked = true };
        } else if (std.mem.eql(u8, prefix, ">")) {
            set = .{ .kind = .quote };
        } else if (prefix.len >= 2 and (prefix[prefix.len - 1] == '.' or prefix[prefix.len - 1] == ')') and std.mem.trim(u8, prefix[0 .. prefix.len - 1], "0123456789").len == 0) {
            set = .{ .kind = .numbers };
        }
        const style = set orelse return;
        try self.editAlone(BlockShortcut{ .ps = ps, .n = rt.runeCount(prefix) + 1, .set = style }, BlockShortcut.run);
    }

    /// Runs an edit as a step of undo of its own, as a shortcut's
    /// conversion does.
    fn editAlone(self: *Editor, ctx: anytype, comptime func: anytype) !void {
        self.publish();
        self.mode = .new;
        try self.editWith(ctx, func);
        self.mode = .new;
        self.coalesce = false;
        self.sel_anchor = self.doc.anchor;
        self.sel_caret = self.doc.caret;
        self.selection_version = self.doc.selection_version;
        self.reveal = true;
    }

    const InlineShortcut = struct {
        start: u32,
        end: u32,
        m: u32,
        mark: Mark,
        fn run(c: @This(), e: *rt.Edit) !void {
            try e.replaceString(c.end, c.end + c.m, "", .{});
            try e.replaceString(c.start, c.start + c.m, "", .{});
            try e.format(c.start, c.end - c.m, c.mark);
            e.select(c.end - c.m, c.end - c.m);
        }
    };
    const Mark = struct {
        kind: enum { bold, italic, code, strike },
        pub fn change(self: Mark, a: *Attributes) void {
            switch (self.kind) {
                .bold => a.weight = 700,
                .italic => a.italic = true,
                .code => a.code = true,
                .strike => a.strikethrough = true,
            }
        }
    };

    /// Formats what a pair of marks typed around words holds: **bold**,
    /// *italic*, _italic_, `code` and ~~strikethrough~~.
    fn inlineShortcut(self: *Editor, ps: u32, before_bytes: []const u8) !void {
        var runes: [512]u21 = undefined;
        var n: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(before_bytes).iterator();
        // Only the end of a long paragraph matters; keep its last runes.
        var total: usize = 0;
        while (it.nextCodepoint()) |c| : (total += 1) {
            if (n == runes.len) {
                std.mem.copyForwards(u21, runes[0 .. runes.len - 1], runes[1..]);
                n -= 1;
            }
            runes[n] = c;
            n += 1;
        }
        const skipped: u32 = @intCast(total - n);
        const before = runes[0..n];
        const last = before[n - 1];
        var m: usize = 1;
        if ((last == '*' or last == '~' or last == '_') and n >= 2 and before[n - 2] == last) m = 2;
        if (last == '~' and m == 1) return;
        const close_at = n - m;
        if (close_at == 0 or isSpaceRune(before[close_at - 1])) return;
        var open: ?usize = null;
        var i = close_at;
        while (i > 0) {
            i -= 1;
            if (i + m >= close_at) continue;
            if (!std.mem.allEqual(u21, before[i .. i + m], last)) continue;
            // Not the inside of a longer mark, and words right after it.
            if ((i > 0 and before[i - 1] == last) or before[i + m] == last or isSpaceRune(before[i + m])) continue;
            // An underscore inside a word, as snake_case, is no mark.
            if (last == '_' and i > 0 and isAlnum(before[i - 1])) continue;
            open = i;
            break;
        }
        const o = open orelse return;
        const mark: Mark = .{ .kind = switch (last) {
            '*', '_' => if (m == 2) .bold else .italic,
            '`' => .code,
            else => .strike,
        } };
        const start = ps + skipped + @as(u32, @intCast(o));
        const end = ps + skipped + @as(u32, @intCast(close_at));
        try self.editAlone(InlineShortcut{ .start = start, .end = end, .m = @intCast(m), .mark = mark }, InlineShortcut.run);
        // What is typed next is outside the format, as after a closing mark.
        const plain = if (start > ps) self.doc.text.attributesAt(start - 1).extending() else Attributes{};
        try self.doc.setTypingAttributes(plain);
    }

    // ---- Pointer ---------------------------------------------------------

    fn press(self: *Editor, p: z.PointerButtonInput) !bool {
        if (p.button != .primary) return false;
        self.press_link.clearRetainingCapacity();
        if (self.overScrollbar(p.position.x)) {
            self.thumb = true;
            const box = self.thumbBox();
            const y = p.position.y - self.bounds.y;
            if (y >= box[0] and y < box[0] + box[1]) {
                self.thumb_grab = y - box[0];
            } else {
                self.thumb_grab = box[1] / 2;
                self.dragThumb(p.position.y);
            }
            return true;
        }
        try self.commitCompose();
        const c = self.contentPoint(p.position);
        const clicks = @max(p.press.window_count, 1);
        if (try self.taskBox(c.x, c.y)) |para| if (clicks == 1 and !self.options.read_only) {
            try self.command(.{ .checked = self.paras.items[para].start });
            return true;
        };
        const at = try self.positionAt(c.x, c.y);
        if (clicks == 1 and !p.modifiers.shift and at.i < self.textLen()) try self.press_link.appendSlice(self.allocator, self.text().attributesAt(at.i).link);
        self.dragging = true;
        self.desired_x = null;
        self.drag_unit = @min(clicks, 3);
        switch (self.drag_unit) {
            1 => self.moveTo(at.i, at.affinity, p.modifiers.shift),
            2 => {
                const w = self.wordAt(at.i);
                self.moveSelectionKeep(w[0], w[1]);
            },
            else => {
                const r = self.text().paragraphRange(at.i);
                self.moveSelectionKeep(r.start, @min(r.end + 1, self.textLen()));
            },
        }
        self.drag_start = .{ self.sel_anchor, self.sel_caret };
        self.coalesce = false;
        return true;
    }

    fn hover(self: *Editor, point: z.Point) !void {
        if (self.paras.items.len == 0 or self.laid_look == null) return;
        const c = self.contentPoint(point);
        var cursor: Cursor = .text;
        if ((try self.taskBox(c.x, c.y)) != null or self.overScrollbar(point.x)) {
            cursor = .arrow;
        } else {
            const at = try self.positionAt(c.x, c.y);
            if (at.i < self.textLen() and self.text().attributesAt(at.i).link.len > 0) cursor = .pointer;
        }
        self.cursor = cursor;
    }

    fn move(self: *Editor, point: z.Point) !bool {
        if (self.thumb) {
            self.dragThumb(point.y);
            return true;
        }
        if (!self.dragging) {
            const before = self.cursor;
            try self.hover(point);
            return before != self.cursor;
        }
        // Near the edges, a drag scrolls.
        const y = point.y - self.bounds.y;
        if (y < self.pad_y) {
            self.setScroll(@max(0, self.scroll - (self.pad_y - y)));
        } else if (y > self.pad_y + self.view_height) self.setScroll(self.scroll + (y - self.pad_y - self.view_height));
        try self.placeView(self.view_height);
        const c = self.contentPoint(point);
        const at = try self.positionAt(c.x, c.y);
        switch (self.drag_unit) {
            2 => {
                const w = self.wordAt(at.i);
                if (at.i < self.drag_start[0]) self.moveSelectionKeep(self.drag_start[1], w[0]) else self.moveSelectionKeep(self.drag_start[0], @max(w[1], self.drag_start[1]));
            },
            3 => {
                const r = self.text().paragraphRange(at.i);
                if (at.i < self.drag_start[0]) self.moveSelectionKeep(self.drag_start[1], r.start) else self.moveSelectionKeep(self.drag_start[0], @min(r.end + 1, self.textLen()));
            },
            else => {
                self.sel_caret = at.i;
                self.affinity = at.affinity;
                self.publish();
            },
        }
        if (at.i != self.drag_start[0] or self.drag_unit != 1) self.press_link.clearRetainingCapacity();
        self.reveal = true;
        return true;
    }

    /// Ends a drag, and opens the link a click began on.
    fn release(self: *Editor) !bool {
        if (self.thumb) {
            self.thumb = false;
            return true;
        }
        if (!self.dragging) return false;
        self.dragging = false;
        if (self.press_link.items.len > 0 and self.sel_caret == self.sel_anchor) {
            const link = self.press_link.items;
            if (self.options.on_link) |opener| {
                opener.call(opener.context, link);
            } else if (safeToOpen(link)) if (self.options.open_url) |opener| opener.call(opener.context, link);
        }
        self.press_link.clearRetainingCapacity();
        return true;
    }

    /// The paragraph whose task's check box (x, y) of the content is on.
    fn taskBox(self: *Editor, x: f32, y: f64) !?usize {
        if (self.paras.items.len == 0) return null;
        const p = self.heights.at(y);
        const st = self.paras.items[p].style;
        if (st.list != .tasks) return null;
        const left = self.insets(st).left;
        if (x < left - self.indentWidth() or x >= left - 2) return null;
        // Beside the first line, where the box is.
        const c = try self.caretAt(self.paras.items[p].start, 0, .downstream);
        return if (y >= c.y and y < c.y + c.h) p else null;
    }

    // ---- Clipboard -------------------------------------------------------

    /// Puts the selection on the clipboard.
    fn copySelection(self: *Editor) !void {
        const clipboard = self.options.clipboard orelse return;
        const sel = self.selection();
        if (sel[0] == sel[1]) return;
        var piece = try self.text().slice(self.allocator, sel[0], sel[1]);
        defer piece.deinit();
        const name = try copies.keep(&piece);
        const rich = try rt.clip.json(self.allocator, &piece, name);
        defer self.allocator.free(rich);
        const h = try rt.html.html(self.allocator, &piece);
        defer self.allocator.free(h);
        const plain = try piece.plainText(self.allocator);
        defer self.allocator.free(plain);
        try clipboard.write(clipboard.context, .{ .rich = rich, .html = h, .text = plain });
    }

    /// Replaces the selection with what the clipboard held: the richest
    /// format the editor reads, or its plain text in the typing attributes
    /// when matching the style. The clipboard's read answers with it.
    pub fn paste(self: *Editor, data: Pasted, match_style: bool) void {
        self.pasteData(data, match_style) catch |err| self.fail(err);
        self.afterInput();
    }

    fn pasteData(self: *Editor, data: Pasted, match_style: bool) !void {
        if (self.options.read_only) return;
        try self.sync();
        var t: ?Text = null;
        defer if (t) |*value| value.deinit();
        if (!match_style) {
            if (data.rich.len > 0) {
                if (try rt.clip.parse(self.allocator, data.rich)) |parsed| {
                    var value = parsed;
                    // A copy of this process pastes as it was.
                    if (try copies.get(self.allocator, value.copy())) |kept| {
                        value.text.deinit();
                        t = kept;
                    } else t = value.text;
                }
            }
            if (t == null and data.html.len > 0) t = try rt.parseHtml(self.allocator, data.html);
            // Word processors copy RTF without HTML.
            if (t == null and data.rtf.len > 0) t = try rt.parseRtf(self.allocator, data.rtf);
            // Markdown applications and views copy it.
            if (t == null and data.markdown.len > 0) t = try rt.parseMarkdown(self.allocator, data.markdown);
        }
        const with = if (t) |*value| value else {
            if (data.text.len > 0) try self.insert(data.text);
            return;
        };
        self.record(false);
        self.publish();
        const sel = self.selection();
        const Ctx = struct {
            a: u32,
            b: u32,
            with: *const Text,
            fn run(c: @This(), e: *rt.Edit) !void {
                try e.replace(c.a, c.b, c.with);
            }
        };
        try self.editWith(Ctx{ .a = sel[0], .b = sel[1], .with = with }, Ctx.run);
        const caret = sel[0] + with.len();
        self.sel_anchor = caret;
        self.sel_caret = caret;
        self.doc.anchor = caret;
        self.doc.caret = caret;
        self.mode = .new;
        self.coalesce = false;
        self.reveal = true;
    }

    // ---- Input methods ---------------------------------------------------

    /// UTF-16 units of the text before rune i.
    pub fn units(self: *const Editor, i: u32) usize {
        const t = self.text();
        const p = t.paraAt(@min(i, t.len()));
        var u: usize = 0;
        var q: u32 = 0;
        while (q < p) : (q += 1) u += utf16Len(t.para(q).text()) + 1;
        const line = t.para(p).text();
        return u + utf16Len(line[0..rt.byteOfRune(line, i - t.paraStart(p))]);
    }

    /// The rune holding UTF-16 unit u, or after it.
    pub fn runeOfUnits(self: *const Editor, u_: usize) u32 {
        const t = self.text();
        var u = u_;
        var start: u32 = 0;
        var q: u32 = 0;
        while (q < t.paragraphCount()) : (q += 1) {
            const line = t.para(q).text();
            const n = utf16Len(line);
            if (u <= n or q + 1 == t.paragraphCount()) {
                var it = std.unicode.Utf8View.initUnchecked(line).iterator();
                var r: u32 = 0;
                var at: usize = 0;
                while (it.nextCodepoint()) |c| {
                    const w: usize = if (c > 0xffff) 2 else 1;
                    if (at + w > u) break;
                    at += w;
                    r += 1;
                }
                return start + r;
            }
            u -= n + 1;
            start += t.para(q).n + 1;
        }
        return t.len();
    }

    fn clientRead(ptr: *anyopaque, _: z.Window, buffer: []u8) anyerror!z.text.Snapshot {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        // The caret's paragraph, as much of it as fits around the caret.
        const t = self.text();
        const p = t.paraAt(@min(self.doc.caret, t.len()));
        const line = t.para(p).text();
        const ps = t.paraStart(p);
        const caret_byte = rt.byteOfRune(line, self.doc.caret - ps);
        const anchor_byte = if (t.paraAt(self.doc.anchor) == p) rt.byteOfRune(line, self.doc.anchor - ps) else caret_byte;
        var lo = @min(caret_byte, anchor_byte);
        var hi = @max(caret_byte, anchor_byte);
        if (hi - lo > buffer.len) {
            lo = caret_byte;
            hi = caret_byte;
        }
        const room = buffer.len - (hi - lo);
        var start = lo -| room / 2;
        while (start > 0 and line[start] & 0xc0 == 0x80) start += 1;
        var end = @min(line.len, hi + (buffer.len - (hi - start)));
        while (end < line.len and end > hi and line[end] & 0xc0 == 0x80) end -= 1;
        @memcpy(buffer[0 .. end - start], line[start..end]);
        const base = self.units(ps) + utf16Len(line[0..start]);
        const anchor = if (t.paraAt(self.doc.anchor) == p) base + utf16Len(line[start..anchor_byte]) else base + utf16Len(line[start..caret_byte]);
        return .{
            .range = .{ .start = base, .end = base + utf16Len(line[start..end]) },
            .selection = .{ .anchor = anchor, .caret = base + utf16Len(line[start..caret_byte]) },
            .revision = self.doc.version,
            .bytes = end - start,
        };
    }

    fn clientChange(ptr: *anyopaque, _: z.Window, change: z.text.Change) anyerror!z.text.ChangeResult {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        try self.sync();
        switch (change) {
            .select => |s| self.moveSelection(self.runeOfUnits(s.anchor), self.runeOfUnits(s.caret)),
            .replace => |r| {
                if (self.options.read_only) return .rejected;
                try self.replaceText(.{ self.runeOfUnits(r.range.start), self.runeOfUnits(r.range.end) }, r.text);
            },
        }
        self.afterInput();
        return .applied;
    }

    fn clientUnbound(ptr: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.client = null;
        self.caret_sent = null;
        self.dropComposeText();
    }
};

// ---- Helpers -----------------------------------------------------------------

/// The last text copied in this process, by the name its clipboard format
/// carries, so that pasting it keeps its attachments. Names start with a
/// number random to the process, so that no other's copy has one.
const copies = struct {
    var text: ?Text = null;
    var name_buffer: [40]u8 = undefined;
    var name_len: usize = 0;
    var counter: u64 = 0;
    var process: u64 = 0;

    fn keep(t: *const Text) ![]const u8 {
        if (process == 0) process = zio.random.int(u64) | 1;
        counter += 1;
        if (text) |*old| old.deinit();
        text = null;
        text = try t.clone(std.heap.page_allocator);
        const name = try std.fmt.bufPrint(&name_buffer, "{x}-{x}", .{ process, counter });
        name_len = name.len;
        return name;
    }

    fn get(allocator: Allocator, name: []const u8) !?Text {
        const kept = &(text orelse return null);
        if (name.len == 0 or !std.mem.eql(u8, name, name_buffer[0..name_len])) return null;
        return try kept.clone(allocator);
    }
};

/// Sets the family of `font` from a CSS family list, as HTML and RTF give
/// it: its first family, generic ones as the platform names them.
pub fn applyFamily(font: *view.Font, list: []const u8) void {
    var names = std.mem.splitScalar(u8, list, ',');
    const first = std.mem.trim(u8, std.mem.trim(u8, names.first(), " \t"), "\"'");
    if (first.len == 0) return;
    if (std.ascii.eqlIgnoreCase(first, "monospace") or std.ascii.eqlIgnoreCase(first, "ui-monospace")) {
        font.monospace = true;
        return;
    }
    if (std.ascii.eqlIgnoreCase(first, "sans-serif") or std.ascii.eqlIgnoreCase(first, "system-ui") or std.ascii.eqlIgnoreCase(first, "ui-sans-serif")) return;
    const name = if (std.ascii.eqlIgnoreCase(first, "serif") or std.ascii.eqlIgnoreCase(first, "ui-serif")) (if (builtin.os.tag == .windows) "Times New Roman" else "Serif") else first;
    // A family past the table's room keeps the interface family.
    font.family = fonts.family(name) catch 0;
}

fn weightOf(w: u16) view.Font.Weight {
    if (w >= 700) return .bold;
    if (w >= 600) return .semibold;
    if (w >= 500) return .medium;
    return .regular;
}

fn uiColor(c: rt.Color) ui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

const isWord = rt.words.isWordRune;

fn isAlnum(r: u21) bool {
    if (r < 0x80) return std.ascii.isAlphanumeric(@intCast(r));
    return isWord(r);
}

const isSpaceRune = rt.words.isSpace;

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |c| n += if (c > 0xffff) @as(usize, 2) else 1;
    return n;
}

/// Newlines as "\n": "\r\n" and lone "\r" alike. Returns `s` itself when
/// it has none to change.
fn normalizeNewlines(allocator: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out = try allocator.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r') {
            out[n] = '\n';
            n += 1;
            if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
        } else {
            out[n] = s[i];
            n += 1;
        }
    }
    return allocator.realloc(out, n) catch out[0..n];
}

/// Whether a paragraph of style st is more than a body paragraph, which
/// Backspace at its start makes it before joining.
fn special(st: ParagraphStyle) bool {
    return st.list != .none or st.heading > 0 or st.quote or st.code_block or st.indent > 0;
}

/// Takes away what Backspace at the start of a paragraph takes first: a
/// level of indentation of a list's item, the list, a heading, a
/// quotation, a block of code.
fn unstyle(s: *ParagraphStyle) void {
    if (s.list != .none and s.indent > 0) {
        s.indent -= 1;
    } else if (s.list != .none) {
        s.list = .none;
        s.checked = false;
    } else if (s.heading > 0) {
        s.heading = 0;
    } else if (s.quote) {
        s.quote = false;
    } else if (s.code_block) {
        s.code_block = false;
    } else if (s.indent > 0) s.indent -= 1;
}

/// What Enter in an empty paragraph leaves: a level of a list, the list, a
/// quotation, a block of code after its other lines.
fn exitBlock(s: *ParagraphStyle, after_code: bool) bool {
    if (s.list != .none and s.indent > 0) {
        s.indent -= 1;
    } else if (s.list != .none) {
        s.list = .none;
        s.checked = false;
    } else if (s.quote) {
        s.quote = false;
    } else if (s.code_block and after_code) {
        s.code_block = false;
    } else return false;
    return true;
}

/// Whether s is a URL, as Ctrl+K links one to itself.
fn looksLikeUrl(s: []const u8) bool {
    if (std.mem.indexOfAny(u8, s, " \n\t") != null or s.len == 0) return false;
    for ([_][]const u8{ "http://", "https://", "mailto:", "www." }) |prefix| if (std.mem.startsWith(u8, s, prefix)) return true;
    return false;
}

/// The command a key with modifiers runs: Ctrl+B, Ctrl+I, Ctrl+U, Ctrl+K,
/// Ctrl+], Ctrl+[, Ctrl+E, Ctrl+L, Ctrl+R; Ctrl+Shift+X, 7, 8, L and E;
/// Ctrl+Alt+0–6, as word processors have them.
pub fn shortcut(k: z.KeyCode, m: z.KeyModifiers) ?Command {
    if (m.super) return null;
    if (m.control and !m.shift and !m.alt) return switch (k) {
        .b => .bold,
        .i => .italic,
        .u => .underline,
        .k => .link,
        .right_bracket => .indent,
        .left_bracket => .outdent,
        .e => .align_center,
        .l => .align_left,
        .r => .align_right,
        else => null,
    };
    if (m.control and m.shift and !m.alt) return switch (k) {
        .x => .strikethrough,
        .digit7 => .numbers,
        .digit8 => .bullets,
        .l => .tasks,
        .e => .code,
        else => null,
    };
    if (m.control and m.alt and !m.shift) return switch (k) {
        .digit0 => .{ .heading = 0 },
        .digit1 => .{ .heading = 1 },
        .digit2 => .{ .heading = 2 },
        .digit3 => .{ .heading = 3 },
        .digit4 => .{ .heading = 4 },
        .digit5 => .{ .heading = 5 },
        .digit6 => .{ .heading = 6 },
        else => null,
    };
    return null;
}

/// n as letters: a, b, … z, aa.
pub fn alphaNumber(n_: u32, out: []u8) []const u8 {
    var n = n_;
    var len: usize = 0;
    while (n > 0 and len < out.len) : (n = (n - 1) / 26) {
        out[out.len - 1 - len] = @intCast('a' + (n - 1) % 26);
        len += 1;
    }
    return out[out.len - len ..];
}

/// n in lowercase Roman numerals.
pub fn romanNumber(n_: u32, out: []u8) []const u8 {
    if (n_ == 0 or n_ >= 4000) return std.fmt.bufPrint(out, "{d}", .{n_}) catch "";
    const values = [_]u32{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
    const symbols = [_][]const u8{ "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
    var n = n_;
    var len: usize = 0;
    for (values, symbols) |v, s| {
        while (n >= v and len + s.len <= out.len) {
            @memcpy(out[len..][0..s.len], s);
            len += s.len;
            n -= v;
        }
    }
    return out[0..len];
}

test {
    _ = @import("heights.zig");
    _ = @import("editor_tests.zig");
    _ = @import("layout_tests.zig");
}
