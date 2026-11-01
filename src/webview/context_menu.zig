//! A page's context menu (Options.context_menu): what was clicked, the
//! engine's own items, and what the app's handler makes of them. The
//! engine shows the menu it changed in place, so its items keep doing what
//! they do; the app's items tell PageEvent.context_menu_command.
const std = @import("std");

/// The engine's items of an open menu at most; later ones cannot be removed.
pub const max_items = 64;
/// The app's items added to one menu at most.
pub const max_additions = 32;
pub const max_label_bytes = 256;

/// Names of the engine's items, the same on both engines where both have
/// the item. Other items keep the engine's own name: WebView2's
/// ("createQrCode"), or the nick of WebKitGTK's stock action
/// ("spelling-guess"); an item named by neither has "".
pub const ids = struct {
    pub const back = "back";
    pub const forward = "forward";
    pub const reload = "reload";
    pub const stop = "stop";
    pub const inspect = "inspect";
    pub const undo = "undo";
    pub const redo = "redo";
    pub const cut = "cut";
    pub const copy = "copy";
    pub const paste = "paste";
    pub const paste_and_match_style = "pasteAndMatchStyle";
    pub const delete = "delete";
    pub const select_all = "selectAll";
    pub const spelling_guess = "spellingGuess";
    pub const open_link = "openLink";
    pub const open_link_in_new_window = "openLinkInNewWindow";
    pub const download_link = "downloadLink";
    pub const copy_link = "copyLink";
    pub const open_image_in_new_window = "openImageInNewWindow";
    pub const download_image = "downloadImage";
    pub const copy_image = "copyImage";
    pub const copy_image_url = "copyImageURL";
    pub const open_frame_in_new_window = "openFrameInNewWindow";
    pub const open_media_in_new_window = "openMediaInNewWindow";
    pub const download_media = "downloadMedia";
    pub const copy_media_url = "copyMediaURL";
    pub const media_controls = "mediaControls";
    pub const media_loop = "mediaLoop";
    pub const media_full_screen = "mediaFullScreen";
    pub const picture_in_picture = "pictureInPicture";
    pub const emoji = "emoji";
    pub const print = "print";
};

pub const Kind = enum(u32) { command, check, radio, separator, submenu };

/// One of the engine's top-level items, borrowed for the handler's call.
/// A submenu is listed as one item; its children stay as the engine made them.
pub const Item = struct {
    id: []const u8,
    /// Without the mnemonic marker.
    label: []const u8,
    kind: Kind,
    enabled: bool,
    checked: bool,
};

/// What the menu opens on, borrowed for the handler's call; null where
/// there is none or the engine does not tell.
pub const Target = struct {
    link_uri: ?[]const u8 = null,
    link_text: ?[]const u8 = null,
    image_uri: ?[]const u8 = null,
    /// A video's or an audio's.
    media_uri: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    /// A text field or editable content, whose menu has the editing items.
    editable: bool = false,
    /// An iframe's URI when it was clicked; WebView2 alone tells it.
    frame_uri: ?[]const u8 = null,
};

/// An item of the app's, after the engine's. Its command, which the app
/// chooses, comes back with PageEvent.context_menu_command when it is
/// chosen. Labels are plain text: no mnemonic is marked.
pub const Addition = union(enum) {
    command: struct { label: []const u8, command: u32, enabled: bool = true },
    check: struct { label: []const u8, command: u32, checked: bool, enabled: bool = true },
    separator,
};

pub const Backend = struct {
    context: *anyopaque,
    append: *const fn (*anyopaque, Addition) error{ TooManyItems, InvalidLabel, OutOfMemory, NativeFailure }!void,
};

/// The menu about to open, which the handler changes before it shows.
pub const Menu = struct {
    target: Target,
    /// The engine's items, as it is about to show them.
    items: []const Item,
    keep: *[max_items]bool,
    backend: Backend,
    additions: u32 = 0,
    prevented: bool = false,

    /// Leaves out every item of the engine's with this id. Separators left
    /// first, last or after another go too.
    pub fn remove(self: *Menu, id: []const u8) void {
        for (self.items, 0..) |item, i| if (i < max_items and std.mem.eql(u8, item.id, id)) {
            self.keep[i] = false;
        };
    }
    pub fn removeAt(self: *Menu, index: usize) void {
        if (index < self.items.len and index < max_items) self.keep[index] = false;
    }
    /// Leaves out all of the engine's items, for a menu of the app's own.
    pub fn removeAll(self: *Menu) void {
        for (0..@min(self.items.len, max_items)) |i| self.keep[i] = false;
    }
    pub fn append(self: *Menu, addition: Addition) !void {
        if (self.additions == max_additions) return error.TooManyItems;
        switch (addition) {
            .command => |value| try validLabel(value.label),
            .check => |value| try validLabel(value.label),
            .separator => {},
        }
        try self.backend.append(self.backend.context, addition);
        self.additions += 1;
    }
    /// Shows no menu at all.
    pub fn prevent(self: *Menu) void {
        self.prevented = true;
    }
};

fn validLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > max_label_bytes or !std.unicode.utf8ValidateSlice(label) or std.mem.indexOfScalar(u8, label, 0) != null) return error.InvalidLabel;
}

/// The id of a WebView2 item by its Name.
pub fn webview2Id(name: []const u8) []const u8 {
    const renamed = [_][2][]const u8{
        .{ "inspectElement", ids.inspect },
        .{ "saveLinkAs", ids.download_link },
        .{ "copyLinkLocation", ids.copy_link },
        .{ "saveImageAs", ids.download_image },
        .{ "copyImageLocation", ids.copy_image_url },
        .{ "saveMediaAs", ids.download_media },
        .{ "copyVideoLocation", ids.copy_media_url },
        .{ "copyAudioLocation", ids.copy_media_url },
        .{ "loop", ids.media_loop },
        .{ "showAllControls", ids.media_controls },
        .{ "spellcheck", ids.spelling_guess },
    };
    for (renamed) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return name;
}

/// The id of a WebKitContextMenuAction; null for the stock actions whose
/// GEnum nick names them (stop, copy, cut, paste, delete and the others).
pub fn webkitId(action: u32) ?[]const u8 {
    return switch (action) {
        0, 10000 => "", // NO_ACTION, CUSTOM
        1 => ids.open_link,
        2 => ids.open_link_in_new_window,
        3 => ids.download_link,
        4 => ids.copy_link,
        5 => ids.open_image_in_new_window,
        6 => ids.download_image,
        7 => ids.copy_image,
        8 => ids.copy_image_url,
        9 => ids.open_frame_in_new_window,
        10 => ids.back,
        11 => ids.forward,
        13 => ids.reload,
        18 => ids.select_all,
        21 => ids.spelling_guess,
        31 => ids.inspect,
        32, 33 => ids.open_media_in_new_window,
        34, 35 => ids.copy_media_url,
        36 => ids.media_controls,
        37 => ids.media_loop,
        38 => ids.media_full_screen,
        42, 43 => ids.download_media,
        44 => ids.emoji,
        45 => ids.paste_and_match_style,
        else => null,
    };
}

/// A label without its mnemonic marker: "&Copy" (WebView2's &, GTK's _) is
/// "Copy", and a doubled marker is the character. Writes to out, cutting a
/// label that does not fit.
pub fn plainLabel(label: []const u8, marker: u8, out: []u8) []const u8 {
    var length: usize = 0;
    var i: usize = 0;
    while (i < label.len and length < out.len) : (i += 1) {
        if (label[i] == marker and i + 1 < label.len) i += 1;
        out[length] = label[i];
        length += 1;
    }
    // Never end inside a UTF-8 sequence.
    while (length > 0 and !std.unicode.utf8ValidateSlice(out[0..length])) length -= 1;
    return out[0..length];
}

test "engine items take the shared ids" {
    try std.testing.expectEqualStrings(ids.inspect, webview2Id("inspectElement"));
    try std.testing.expectEqualStrings("createQrCode", webview2Id("createQrCode"));
    try std.testing.expectEqualStrings(ids.reload, webkitId(13).?);
    try std.testing.expectEqualStrings("", webkitId(10000).?);
    try std.testing.expect(webkitId(12) == null);
}

test "labels lose their mnemonics" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Copy", plainLabel("&Copy", '&', &out));
    try std.testing.expectEqualStrings("Save & quit", plainLabel("Save && quit", '&', &out));
    try std.testing.expectEqualStrings("Open_Link", plainLabel("_Open__Link", '_', &out));
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("ab", plainLabel("ab\u{00e9}", '&', small[0..3]));
}

test "a handler changes the menu within its bounds" {
    const Recorder = struct {
        count: u32 = 0,
        fn append(ptr: *anyopaque, _: Addition) error{ TooManyItems, InvalidLabel, OutOfMemory, NativeFailure }!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
    };
    var recorder: Recorder = .{};
    var keep: [max_items]bool = @splat(true);
    const items = [_]Item{
        .{ .id = ids.back, .label = "Back", .kind = .command, .enabled = true, .checked = false },
        .{ .id = "", .label = "", .kind = .separator, .enabled = true, .checked = false },
        .{ .id = ids.reload, .label = "Reload", .kind = .command, .enabled = true, .checked = false },
    };
    var menu: Menu = .{ .target = .{}, .items = &items, .keep = &keep, .backend = .{ .context = &recorder, .append = Recorder.append } };
    menu.remove(ids.reload);
    try std.testing.expect(keep[0] and keep[1] and !keep[2]);
    try menu.append(.{ .command = .{ .label = "Open in browser", .command = 7 } });
    try std.testing.expectError(error.InvalidLabel, menu.append(.{ .command = .{ .label = "", .command = 8 } }));
    for (1..max_additions) |_| try menu.append(.separator);
    try std.testing.expectError(error.TooManyItems, menu.append(.separator));
    try std.testing.expectEqual(@as(u32, max_additions), recorder.count);
}
