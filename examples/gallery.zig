//! A widget gallery: a sidebar list of pages beside a scrolling page that
//! shows most `ziggurat_view` controls, each bound directly to a field of
//! `Gallery`. It covers buttons, links, navigation buttons, badges and
//! avatars; checkboxes, switches, radios, segments and tabs; sliders,
//! steppers, progress, meters and ratings; breadcrumbs, disclosures and
//! accordions; list boxes, combo boxes, trees and sortable tables; form
//! fields and fieldsets; tooltips and toasts. The split and scroll
//! containers frame the whole page.
//!
//! Tooltip delays and toast durations are served by `ziggurat_view_timer`:
//! it arms one one-shot timer for the earliest deadline the build asked for,
//! and nothing runs while the window is idle.
//!
//! Run it with `zig build run-gallery`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");

const Page = enum { buttons, choices, values, navigation, collections, forms, feedback };
const page_titles = [_][]const u8{ "Buttons", "Choices", "Values", "Navigation", "Collections", "Forms", "Feedback" };

const Size = enum { small, medium, large };
const Section = enum { shipping, returns, warranty };
const Tab = enum { overview, details, history };
const Color = enum { red, green, blue };

const File = struct { id: u64, name: []const u8, kind: []const u8, kilobytes: u32 };
const muted: u32 = 0x6b7785;

const Gallery = struct {
    page: Page = .buttons,
    sidebar: f64 = 0.24,
    content: view.ScrollModel = .{},
    // Buttons
    presses: u32 = 0,
    // Choices
    wifi: bool = true,
    bluetooth: bool = false,
    subscribe: bool = true,
    size: Size = .medium,
    tab: Tab = .overview,
    // Values
    volume: f64 = 40,
    copies: f64 = 2,
    stars: u8 = 3,
    // Navigation
    advanced: bool = false,
    open_section: ?Section = .shipping,
    // Collections
    color: Color = .green,
    list_choice: Size = .small,
    folders: [2]bool = .{ true, false },
    tree_ids: [1]u64 = undefined,
    tree_selection: view.Selection = undefined,
    table_ids: [8]u64 = undefined,
    table_selection: view.Selection = undefined,
    sort: ?view.Sort = null,
    files: [5]File = .{
        .{ .id = 1, .name = "notes.txt", .kind = "Text", .kilobytes = 4 },
        .{ .id = 2, .name = "photo.png", .kind = "Image", .kilobytes = 812 },
        .{ .id = 3, .name = "build.zig", .kind = "Source", .kilobytes = 12 },
        .{ .id = 4, .name = "song.ogg", .kind = "Audio", .kilobytes = 3150 },
        .{ .id = 5, .name = "report.pdf", .kind = "Document", .kilobytes = 240 },
    },
    // Forms
    quantity: f64 = 3,
    gift: bool = false,
    // Feedback
    toasts: view.Toasts(4) = .{},
    undone: u32 = 0,

    /// Selections borrow their storage from the struct, so initialize them
    /// once it has its final address.
    fn init(self: *Gallery) void {
        self.* = .{};
        self.tree_selection = view.Selection.init(.single, &self.tree_ids);
        self.table_selection = view.Selection.init(.multiple, &self.table_ids);
    }

    fn build(self: *Gallery, v: *view.View) anyerror!void {
        _ = try v.split(.row, &self.sidebar, .{ .minimum = 0.15, .maximum = 0.45 }, .{ .grow = 1, .self_align = .stretch, .name = "Sidebar" });
        try v.listBox(.{ .name = "Pages", .padding = view.Insets.all(4) });
        for (page_titles, 0..) |title, index| {
            if (try v.listItem(Page, &self.page, @enumFromInt(index), title, .{})) self.content.offset = .{};
        }
        try v.end();
        try v.scroll(&self.content, .{ .padding = .{ .left = 16, .right = 16 }, .gap = 12 });
        try v.text(page_titles[@intFromEnum(self.page)], .{ .font = view.Font.heading2 });
        switch (self.page) {
            .buttons => try self.buttons(v),
            .choices => try self.choices(v),
            .values => try self.values(v),
            .navigation => try self.navigation(v),
            .collections => try self.collections(v),
            .forms => try self.forms(v),
            .feedback => try self.feedback(v),
        }
        try v.end();
        try v.end();
        // Toasts float over the bottom of the window wherever they are built.
        if (try v.toasts(&self.toasts, .{})) |_| self.undone += 1;
    }

    fn buttons(self: *Gallery, v: *view.View) !void {
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("Press me", .{})) self.presses += 1;
        _ = try v.button("Disabled", .{ .enabled = false });
        if (try v.link("Reset count", .{ .enabled = self.presses != 0 })) self.presses = 0;
        try v.end();
        try v.textf("Pressed {d} times", .{self.presses}, .{ .color = muted });
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.navButton(.back, .{})) self.presses -|= 1;
        if (try v.navButton(.forward, .{})) self.presses += 1;
        try v.badge("New", .{});
        try v.badge("3 unread", .{ .background = 0x2f7d4f });
        try v.avatar("Ada Lovelace", null, .{});
        try v.avatar("Grace Hopper", null, .{});
        try v.end();
    }

    fn choices(self: *Gallery, v: *view.View) !void {
        _ = try v.checkbox(&self.subscribe, "Subscribe to updates", .{});
        _ = try v.toggleSwitch(&self.wifi, "Wi-Fi", .{});
        _ = try v.toggleSwitch(&self.bluetooth, "Bluetooth", .{});
        try v.radioGroup(.{ .name = "Size", .gap = 4 });
        _ = try v.radio(Size, &self.size, .small, "Small", .{});
        _ = try v.radio(Size, &self.size, .medium, "Medium", .{});
        _ = try v.radio(Size, &self.size, .large, "Large", .{});
        try v.end();
        try v.segmented(.{ .name = "Size" });
        _ = try v.segment(Size, &self.size, .small, "S", .{});
        _ = try v.segment(Size, &self.size, .medium, "M", .{});
        _ = try v.segment(Size, &self.size, .large, "L", .{});
        try v.end();
        try v.tabs(.{ .name = "Sections" });
        _ = try v.tab(Tab, &self.tab, .overview, "Overview", .{});
        _ = try v.tab(Tab, &self.tab, .details, "Details", .{});
        _ = try v.tab(Tab, &self.tab, .history, "History", .{});
        try v.end();
        try v.text(switch (self.tab) {
            .overview => "Tabs select a value; the app builds the page below.",
            .details => "Arrow keys move between tabs and select them.",
            .history => "Unselected pages keep no state in the view.",
        }, .{ .color = muted });
    }

    fn values(self: *Gallery, v: *view.View) !void {
        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        try v.textf("Volume {d:.0}", .{self.volume}, .{ .width = 96 });
        _ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 100, .step = 5 }, .{ .grow = 1, .name = "Volume" });
        try v.end();
        try v.progress(@floatCast(self.volume / 100), .{ .self_align = .stretch, .name = "Volume level" });
        try v.text("Meter: storage used, outside 10–80 GB is a caution", .{ .color = muted });
        try v.meter(self.volume, .{ .minimum = 0, .maximum = 100 }, .{ .low = 10, .high = 80 }, .{ .self_align = .stretch, .name = "Storage used" });
        try v.row(.{ .gap = 12, .alignment = .center });
        try v.text("Copies", .{});
        _ = try v.stepper(&self.copies, .{ .minimum = 1, .maximum = 9, .step = 1 }, .{ .name = "Copies" });
        try v.textf("{d:.0}", .{self.copies}, .{});
        try v.end();
        try v.row(.{ .gap = 12, .alignment = .center });
        try v.text("Rating", .{});
        _ = try v.rating(&self.stars, 5, .{ .name = "Rating" });
        try v.textf("{d} of 5", .{self.stars}, .{});
        try v.end();
    }

    fn navigation(self: *Gallery, v: *view.View) !void {
        try v.breadcrumbs(.{ .name = "Location" });
        if (try v.link("Home", .{})) self.page = .buttons;
        if (try v.link("Gallery", .{})) self.page = .buttons;
        try v.text("Navigation", .{});
        try v.end();
        _ = try v.disclosure(&self.advanced, "Advanced options", .{});
        if (self.advanced) try v.text("Hidden until the disclosure is expanded.", .{ .color = muted, .padding = .{ .left = 24 } });
        try v.accordion(.{ .name = "Help", .self_align = .stretch });
        const sections = [_]struct { Section, []const u8, []const u8 }{
            .{ .shipping, "Shipping", "Orders ship within two days." },
            .{ .returns, "Returns", "Return any item within thirty days." },
            .{ .warranty, "Warranty", "Every device has a one-year warranty." },
        };
        for (sections) |entry| {
            _ = try v.section(Section, &self.open_section, entry[0], entry[1], .{});
            if (self.open_section == entry[0]) try v.text(entry[2], .{ .color = muted });
        }
        try v.end();
    }

    fn collections(self: *Gallery, v: *view.View) !void {
        try v.row(.{ .gap = 16, .alignment = .start, .self_align = .stretch });
        try v.column(.{ .gap = 8 });
        try v.listBox(.{ .name = "Size", .width = 140 });
        _ = try v.listItem(Size, &self.list_choice, .small, "Small", .{});
        _ = try v.listItem(Size, &self.list_choice, .medium, "Medium", .{});
        _ = try v.listItem(Size, &self.list_choice, .large, "Large", .{});
        try v.end();
        try v.comboBox(@tagName(self.color), .{ .name = "Color", .width = 140 });
        _ = try v.comboOption(Color, &self.color, .red, "red", .{});
        _ = try v.comboOption(Color, &self.color, .green, "green", .{});
        _ = try v.comboOption(Color, &self.color, .blue, "blue", .{});
        try v.end();
        try v.end();
        try v.tree(&self.tree_selection, .{ .name = "Folders", .grow = 1 });
        _ = try v.treeItem(10, &self.folders[0], "Documents", .{});
        if (self.folders[0]) {
            _ = try v.treeItem(11, null, "letter.txt", .{});
            try v.end();
            _ = try v.treeItem(12, null, "budget.csv", .{});
            try v.end();
        }
        try v.end();
        _ = try v.treeItem(20, &self.folders[1], "Pictures", .{});
        if (self.folders[1]) {
            _ = try v.treeItem(21, null, "beach.jpg", .{});
            try v.end();
        }
        try v.end();
        try v.end();
        try v.end();

        const columns = [_]view.Column{
            .{ .title = "Name", .track = view.Track.fraction(2) },
            .{ .title = "Kind" },
            .{ .title = "Size", .track = view.Track.fixed(90) },
        };
        if (try v.table(&columns, &self.sort, &self.table_selection, .{ .name = "Files", .self_align = .stretch })) self.sortFiles();
        for (self.files) |file| {
            _ = try v.tableRow(file.id, file.name, .{});
            try v.text(file.name, .{});
            try v.text(file.kind, .{});
            try v.textf("{d} KB", .{file.kilobytes}, .{});
            try v.end();
        }
        try v.end();
        try v.textf("{d} selected; Ctrl or Shift extends the selection", .{self.table_selection.items().len}, .{ .color = muted });
    }

    fn sortFiles(self: *Gallery) void {
        const sort = self.sort orelse return;
        const Order = struct {
            fn less(by: view.Sort, a: File, b: File) bool {
                const before = switch (by.column) {
                    0 => std.mem.order(u8, a.name, b.name) == .lt,
                    1 => std.mem.order(u8, a.kind, b.kind) == .lt,
                    else => a.kilobytes < b.kilobytes,
                };
                const after = switch (by.column) {
                    0 => std.mem.order(u8, b.name, a.name) == .lt,
                    1 => std.mem.order(u8, b.kind, a.kind) == .lt,
                    else => b.kilobytes < a.kilobytes,
                };
                return if (by.direction == .ascending) before else after;
            }
        };
        std.mem.sort(File, &self.files, sort, Order.less);
    }

    fn forms(self: *Gallery, v: *view.View) !void {
        try v.fieldset("Order", .{ .self_align = .stretch });
        try v.field("Quantity", .{
            .help = "Between 1 and 5 per order.",
            .@"error" = if (self.quantity > 5) "Too many: at most 5 per order." else null,
            .required = true,
        }, .{});
        _ = try v.stepper(&self.quantity, .{ .minimum = 1, .maximum = 10, .step = 1 }, .{});
        try v.end();
        try v.field("Size", .{ .help = "Shared with the Choices page." }, .{});
        try v.segmented(.{});
        _ = try v.segment(Size, &self.size, .small, "Small", .{});
        _ = try v.segment(Size, &self.size, .medium, "Medium", .{});
        _ = try v.segment(Size, &self.size, .large, "Large", .{});
        try v.end();
        try v.end();
        _ = try v.checkbox(&self.gift, "Wrap as a gift", .{});
        try v.end();
        try v.textf("Order: {d:.0} × {s}{s}", .{ self.quantity, @tagName(self.size), if (self.gift) ", gift-wrapped" else "" }, .{ .color = muted });
    }

    fn feedback(self: *Gallery, v: *view.View) !void {
        try v.text("Hover or focus a button to see its tooltip.", .{ .color = muted });
        try v.row(.{ .gap = 8 });
        if (try v.button("Show toast", .{})) _ = try self.toasts.show("Saved a copy to Documents.", .{});
        try v.tooltip("Shows a message for four seconds");
        if (try v.button("Delete with undo", .{})) _ = try self.toasts.show("Moved one item to the trash.", .{ .action = "Undo", .duration = 8 * std.time.ns_per_s });
        try v.tooltip("The message offers an Undo action");
        if (try v.button("Sticky toast", .{})) _ = try self.toasts.show("Stays until dismissed.", .{ .duration = 0 });
        try v.tooltip("Duration 0 keeps the message until it is closed");
        try v.end();
        try v.textf("Undo pressed {d} times", .{self.undone}, .{ .color = muted });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gallery: Gallery = undefined;
    gallery.init();
    var storage: view.Storage(256, 8192) = .{};
    var host = view.Host.init(&gallery, Gallery.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(12) } });
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Widget gallery", .width = 860, .height = 600, .min_width = 560, .min_height = 400 });
    try host.attach(window);
    try timer.attach(app, allocator);
    // Runs before app.deinit: release the one-shot timer after the loop.
    defer timer.close() catch {};
    window.show();
    try app.run();
}

test "every page records within the frame's limits" {
    const ui = @import("ziggurat_ui");
    const Unused = struct {
        fn draw(_: *anyopaque, _: *ui.Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var gallery: Gallery = undefined;
    gallery.init();
    _ = try gallery.toasts.show("Saved.", .{ .action = "Undo" });
    var storage: view.Storage(256, 8192) = .{};
    var h = view.Harness.init(&gallery, Gallery.build, storage.buffers(), .{});
    var context = ui.Context.init(&gallery, Unused.draw, Unused.action);
    try h.attachInput(&context);
    for (0..page_titles.len) |index| {
        gallery.page = @enumFromInt(index);
        gallery.advanced = true;
        try h.render();
    }
}

test "pages respond to input" {
    var gallery: Gallery = undefined;
    gallery.init();
    var storage: view.Storage(256, 8192) = .{};
    var h = view.Harness.init(&gallery, Gallery.build, storage.buffers(), .{});
    try h.render();
    try h.click(.{ .text = "Press me" });
    try std.testing.expectEqual(@as(u32, 1), gallery.presses);

    gallery.page = .collections;
    try h.render();
    try h.click(.{ .text = "Size", .kind = .column_header });
    try std.testing.expectEqualStrings("notes.txt", gallery.files[0].name);
    try h.click(.{ .text = "Size", .kind = .column_header });
    try std.testing.expectEqualStrings("song.ogg", gallery.files[0].name);

    gallery.page = .feedback;
    try h.render();
    try h.click(.{ .text = "Delete with undo" });
    try h.click(.{ .text = "Undo" });
    try std.testing.expectEqual(@as(u32, 1), gallery.undone);
    try std.testing.expectEqual(@as(usize, 0), gallery.toasts.len);
}
