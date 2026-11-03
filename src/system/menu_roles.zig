//! Standard menu roles: the labels and accelerators of common commands in
//! the language the application shows, and the default items of the
//! standard submenus. Nothing here touches native state; a Builder fills
//! caller storage with ordinary `Item`s for `setMenu`, `popupMenu` or a tray.
//! Changing language means building again with the new locale and setting
//! the menu again.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const types = @import("types.zig");
const menus = @import("menus.zig");

pub const Role = enum {
    undo,
    redo,
    cut,
    copy,
    paste,
    paste_and_match_style,
    delete,
    select_all,
    reload,
    force_reload,
    toggle_dev_tools,
    reset_zoom,
    zoom_in,
    zoom_out,
    toggle_full_screen,
    minimize,
    zoom,
    close,
    new,
    open,
    open_recent,
    save,
    save_as,
    duplicate,
    rename,
    move_to,
    revert,
    quit,
    about,
    hide,
    hide_others,
    unhide,
    front,
    services,
    start_speaking,
    stop_speaking,
    window,
    help,
    app_menu,
    file_menu,
    edit_menu,
    view_menu,
    window_menu,
    format_menu,
    bold,
    italic,
    underline,
    strikethrough,
    align_left,
    align_center,
    align_right,

    /// Roles whose items open a submenu.
    pub fn isSubmenu(self: Role) bool {
        return switch (self) {
            .open_recent, .services, .window, .help, .app_menu, .file_menu, .edit_menu, .view_menu, .window_menu, .format_menu => true,
            else => false,
        };
    }
    /// The command ID a Builder gives this role's first item; a role used
    /// again, as Close in both the File and Window menus, gets the next
    /// occurrence. `fromId` maps any of them back; applications keep their
    /// own IDs below `id_base`.
    pub fn id(self: Role) u64 {
        return self.occurrenceId(0);
    }
    pub fn occurrenceId(self: Role, occurrence: u8) u64 {
        return id_base + (@as(u64, occurrence) << 8) + @backingInt(self);
    }
    pub fn fromId(value: u64) ?Role {
        if (value < id_base) return null;
        const offset = value - id_base;
        if (offset >> 16 != 0 or offset & 0xff >= zio.fields(Role).len) return null;
        return @fromBackingInt(@intCast(offset & 0xff));
    }
};

pub const id_base: u64 = 0xffff_0000_0000_0000;
/// The Open Recent submenu's items, from `Builder.recentDocuments`.
pub const recent_document_base: u64 = id_base + 0x1_0000;
pub const clear_recent_id: u64 = id_base + 0x2_0000;
/// The index into the paths `recentDocuments` was given, for a chosen item.
pub fn recentDocumentIndex(value: u64) ?usize {
    if (value < recent_document_base or value >= recent_document_base + 0x1_0000) return null;
    return @intCast(value - recent_document_base);
}

/// One language. Empty fields fall back to English. `{app}` is the
/// application name.
pub const Strings = struct {
    undo: []const u8 = "",
    redo: []const u8 = "",
    cut: []const u8 = "",
    copy: []const u8 = "",
    paste: []const u8 = "",
    paste_and_match_style: []const u8 = "",
    delete: []const u8 = "",
    select_all: []const u8 = "",
    reload: []const u8 = "",
    force_reload: []const u8 = "",
    toggle_dev_tools: []const u8 = "",
    actual_size: []const u8 = "",
    zoom_in: []const u8 = "",
    zoom_out: []const u8 = "",
    toggle_full_screen: []const u8 = "",
    minimize: []const u8 = "",
    zoom: []const u8 = "",
    bring_all_to_front: []const u8 = "",
    close: []const u8 = "",
    close_window: []const u8 = "",
    new: []const u8 = "",
    open: []const u8 = "",
    open_recent: []const u8 = "",
    save: []const u8 = "",
    save_as: []const u8 = "",
    duplicate: []const u8 = "",
    rename: []const u8 = "",
    move_to: []const u8 = "",
    revert: []const u8 = "",
    revert_to_saved: []const u8 = "",
    quit_app: []const u8 = "",
    about: []const u8 = "",
    hide: []const u8 = "",
    quit: []const u8 = "",
    exit: []const u8 = "",
    hide_others: []const u8 = "",
    show_all: []const u8 = "",
    services: []const u8 = "",
    start_speaking: []const u8 = "",
    stop_speaking: []const u8 = "",
    file: []const u8 = "",
    edit: []const u8 = "",
    view: []const u8 = "",
    format: []const u8 = "",
    window: []const u8 = "",
    help: []const u8 = "",
    bold: []const u8 = "",
    italic: []const u8 = "",
    underline: []const u8 = "",
    strikethrough: []const u8 = "",
    align_left: []const u8 = "",
    center: []const u8 = "",
    align_right: []const u8 = "",
    speech: []const u8 = "",
    clear_recent: []const u8 = "",

    pub fn merge(self: Strings, fallback: Strings) Strings {
        var result = self;
        inline for (zio.fields(Strings)) |field| {
            if (@field(result, field.name).len == 0) @field(result, field.name) = @field(fallback, field.name);
        }
        return result;
    }
};

pub const Language = struct { tag: []const u8, strings: Strings };

pub const english: Strings = .{
    .undo = "Undo",
    .redo = "Redo",
    .cut = "Cut",
    .copy = "Copy",
    .paste = "Paste",
    .paste_and_match_style = "Paste and Match Style",
    .delete = "Delete",
    .select_all = "Select All",
    .reload = "Reload",
    .force_reload = "Force Reload",
    .toggle_dev_tools = "Toggle Developer Tools",
    .actual_size = "Actual Size",
    .zoom_in = "Zoom In",
    .zoom_out = "Zoom Out",
    .toggle_full_screen = "Toggle Full Screen",
    .minimize = "Minimize",
    .zoom = "Zoom",
    .bring_all_to_front = "Bring All to Front",
    .close = "Close",
    .close_window = "Close Window",
    .new = "New",
    .open = "Open…",
    .open_recent = "Open Recent",
    .save = "Save",
    .save_as = "Save As…",
    .duplicate = "Duplicate",
    .rename = "Rename…",
    .move_to = "Move To…",
    .revert = "Revert",
    .revert_to_saved = "Revert to Saved",
    .quit_app = "Quit {app}",
    .about = "About {app}",
    .hide = "Hide {app}",
    .quit = "Quit",
    .exit = "Exit",
    .hide_others = "Hide Others",
    .show_all = "Show All",
    .services = "Services",
    .start_speaking = "Start Speaking",
    .stop_speaking = "Stop Speaking",
    .file = "File",
    .edit = "Edit",
    .view = "View",
    .format = "Format",
    .window = "Window",
    .help = "Help",
    .bold = "Bold",
    .italic = "Italic",
    .underline = "Underline",
    .strikethrough = "Strikethrough",
    .align_left = "Align Left",
    .center = "Center",
    .align_right = "Align Right",
    .speech = "Speech",
    .clear_recent = "Clear Menu",
};

/// Shipped languages by BCP 47 tag.
pub const languages = [_]Language{
    .{ .tag = "en", .strings = english },
    .{ .tag = "zh-Hans", .strings = .{
        .undo = "撤销",
        .redo = "重做",
        .cut = "剪切",
        .copy = "复制",
        .paste = "粘贴",
        .paste_and_match_style = "粘贴并匹配样式",
        .delete = "删除",
        .select_all = "全选",
        .reload = "重新载入",
        .force_reload = "强制重新载入",
        .toggle_dev_tools = "切换开发者工具",
        .actual_size = "实际大小",
        .zoom_in = "放大",
        .zoom_out = "缩小",
        .toggle_full_screen = "切换全屏幕",
        .minimize = "最小化",
        .zoom = "缩放",
        .bring_all_to_front = "前置全部窗口",
        .close = "关闭",
        .close_window = "关闭窗口",
        .new = "新建",
        .open = "打开…",
        .open_recent = "打开最近使用",
        .save = "保存",
        .save_as = "另存为…",
        .duplicate = "创建副本",
        .rename = "重新命名…",
        .move_to = "移到…",
        .revert = "还原",
        .revert_to_saved = "还原到上次存储的版本",
        .quit_app = "退出{app}",
        .about = "关于{app}",
        .hide = "隐藏{app}",
        .quit = "退出",
        .exit = "退出",
        .hide_others = "隐藏其他",
        .show_all = "全部显示",
        .services = "服务",
        .start_speaking = "开始讲话",
        .stop_speaking = "停止讲话",
        .file = "文件",
        .edit = "编辑",
        .view = "显示",
        .format = "格式",
        .window = "窗口",
        .help = "帮助",
        .bold = "粗体",
        .italic = "斜体",
        .underline = "下划线",
        .strikethrough = "删除线",
        .align_left = "左对齐",
        .center = "居中",
        .align_right = "右对齐",
        .speech = "语音",
        .clear_recent = "清除菜单",
    } },
    .{ .tag = "zh-Hant", .strings = .{
        .undo = "復原",
        .redo = "重做",
        .cut = "剪下",
        .copy = "複製",
        .paste = "貼上",
        .paste_and_match_style = "貼上並符合樣式",
        .delete = "刪除",
        .select_all = "全選",
        .reload = "重新載入",
        .force_reload = "強制重新載入",
        .toggle_dev_tools = "切換開發者工具",
        .actual_size = "實際大小",
        .zoom_in = "放大",
        .zoom_out = "縮小",
        .toggle_full_screen = "切換全螢幕",
        .minimize = "最小化",
        .zoom = "縮放",
        .bring_all_to_front = "將全部視窗移至最前",
        .close = "關閉",
        .close_window = "關閉視窗",
        .new = "新增",
        .open = "開啟…",
        .open_recent = "打開最近使用過的檔案",
        .save = "儲存",
        .save_as = "另存新檔…",
        .duplicate = "製作副本",
        .rename = "重新命名…",
        .move_to = "移至…",
        .revert = "回復",
        .revert_to_saved = "回復至上次儲存的版本",
        .quit_app = "結束{app}",
        .about = "關於{app}",
        .hide = "隱藏{app}",
        .quit = "結束",
        .exit = "結束",
        .hide_others = "隱藏其他",
        .show_all = "顯示全部",
        .services = "服務",
        .start_speaking = "開始朗讀",
        .stop_speaking = "停止朗讀",
        .file = "檔案",
        .edit = "編輯",
        .view = "顯示方式",
        .format = "格式",
        .window = "視窗",
        .help = "輔助說明",
        .bold = "粗體",
        .italic = "斜體",
        .underline = "底線",
        .strikethrough = "刪除線",
        .align_left = "靠左對齊",
        .center = "置中",
        .align_right = "靠右對齊",
        .speech = "語音",
        .clear_recent = "清除選單",
    } },
    .{ .tag = "ja", .strings = .{
        .undo = "取り消す",
        .redo = "やり直す",
        .cut = "カット",
        .copy = "コピー",
        .paste = "ペースト",
        .paste_and_match_style = "ペーストしてスタイルを合わせる",
        .delete = "削除",
        .select_all = "すべてを選択",
        .reload = "再読み込み",
        .force_reload = "強制再読み込み",
        .toggle_dev_tools = "開発者ツールの切り替え",
        .actual_size = "実際のサイズ",
        .zoom_in = "拡大",
        .zoom_out = "縮小",
        .toggle_full_screen = "フルスクリーンの切り替え",
        .minimize = "しまう",
        .zoom = "拡大/縮小",
        .bring_all_to_front = "すべてを手前に移動",
        .close = "閉じる",
        .close_window = "ウインドウを閉じる",
        .new = "新規",
        .open = "開く…",
        .open_recent = "最近使った項目を開く",
        .save = "保存",
        .save_as = "別名で保存…",
        .duplicate = "複製",
        .rename = "名称変更…",
        .move_to = "移動…",
        .revert = "復帰",
        .revert_to_saved = "保存時の状態に戻す",
        .quit_app = "{app}を終了",
        .about = "{app}について",
        .hide = "{app}を隠す",
        .quit = "終了",
        .exit = "終了",
        .hide_others = "ほかを隠す",
        .show_all = "すべてを表示",
        .services = "サービス",
        .start_speaking = "読み上げを開始",
        .stop_speaking = "読み上げを停止",
        .file = "ファイル",
        .edit = "編集",
        .view = "表示",
        .format = "フォーマット",
        .window = "ウインドウ",
        .help = "ヘルプ",
        .bold = "太字",
        .italic = "斜体",
        .underline = "下線",
        .strikethrough = "取り消し線",
        .align_left = "左揃え",
        .center = "中央揃え",
        .align_right = "右揃え",
        .speech = "スピーチ",
        .clear_recent = "メニューを消去",
    } },
};

/// The shipped language closest to `locale`, such as "zh-TW" or "de_AT":
/// Chinese picks its script from the script or region, other languages
/// match on the primary subtag, and anything else is English.
pub fn shipped(locale: []const u8) Language {
    var primary_buffer: [8]u8 = undefined;
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    if (end == 0 or end > primary_buffer.len) return languages[0];
    const primary = std.ascii.lowerString(&primary_buffer, locale[0..end]);
    if (std.mem.eql(u8, primary, "zh")) {
        const rest = locale[end..];
        const traditional = for ([_][]const u8{ "hant", "tw", "hk", "mo" }) |needle| {
            if (std.ascii.findIgnoreCase(rest, needle) != null) break true;
        } else false;
        return find(if (traditional) "zh-Hant" else "zh-Hans").?;
    }
    return find(primary) orelse languages[0];
}

pub fn find(tag: []const u8) ?Language {
    for (languages) |language| if (std.ascii.eqlIgnoreCase(language.tag, tag)) return language;
    return null;
}

/// The strings for `locale`: application overrides for the exact or primary
/// tag first, then the shipped language, then English.
pub fn resolve(locale: []const u8, overrides: []const Language) Strings {
    const base = shipped(locale);
    var result = base.strings.merge(english);
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    for (overrides) |language| {
        const matches = std.ascii.eqlIgnoreCase(language.tag, locale) or std.ascii.eqlIgnoreCase(language.tag, base.tag) or std.ascii.eqlIgnoreCase(language.tag, locale[0..end]);
        if (matches) result = language.strings.merge(result);
    }
    return result;
}

pub const Platform = enum { windows, linux, macos };
pub const native_platform: Platform = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .macos,
    else => .linux,
};

pub const Context = struct {
    strings: Strings = english,
    /// Replaces `{app}` and names the application menu.
    app_name: []const u8 = "",
    platform: Platform = native_platform,
    /// The application edits documents: the File menu then carries the
    /// document commands and Close names a document rather than a window.
    documents: bool = false,
};

pub const Defaults = struct {
    /// A label format; `{app}` is replaced by `Context.app_name`.
    label: []const u8,
    accelerator: ?types.Accelerator = null,
};

/// The label and accelerator a role's item takes. Accelerators use Control
/// on Windows and Linux and Command (`Modifiers.super`) on macOS, where the
/// roles also take the shortcuts of their standard macOS items, as Cmd+Q
/// for Quit and Cmd+H for Hide.
pub fn defaults(role: Role, context: Context) Defaults {
    const tx = context.strings;
    const mac = context.platform == .macos;
    const primary: types.Modifiers = if (mac) .{ .super = true } else .{ .control = true };
    const keys = struct {
        primary: types.Modifiers,
        fn key(self: @This(), value: types.Key) ?types.Accelerator {
            return .{ .key = value, .modifiers = self.primary };
        }
        fn with(self: @This(), value: types.Key, extra: types.Modifiers) ?types.Accelerator {
            var modifiers = self.primary;
            modifiers.shift = modifiers.shift or extra.shift;
            modifiers.alt = modifiers.alt or extra.alt;
            modifiers.control = modifiers.control or extra.control;
            return .{ .key = value, .modifiers = modifiers };
        }
    };
    const ctrl: keys = .{ .primary = primary };
    const shift: types.Modifiers = .{ .shift = true };
    return switch (role) {
        .undo => .{ .label = tx.undo, .accelerator = ctrl.key(.z) },
        .redo => .{ .label = tx.redo, .accelerator = if (context.platform == .windows) ctrl.key(.y) else ctrl.with(.z, shift) },
        .cut => .{ .label = tx.cut, .accelerator = ctrl.key(.x) },
        .copy => .{ .label = tx.copy, .accelerator = ctrl.key(.c) },
        .paste => .{ .label = tx.paste, .accelerator = ctrl.key(.v) },
        .paste_and_match_style => .{ .label = tx.paste_and_match_style, .accelerator = ctrl.with(.v, .{ .shift = true, .alt = true }) },
        .delete => .{ .label = tx.delete },
        .select_all => .{ .label = tx.select_all, .accelerator = ctrl.key(.a) },
        .reload => .{ .label = tx.reload, .accelerator = ctrl.key(.r) },
        .force_reload => .{ .label = tx.force_reload, .accelerator = ctrl.with(.r, shift) },
        .toggle_dev_tools => .{ .label = tx.toggle_dev_tools, .accelerator = if (mac) ctrl.with(.i, .{ .alt = true }) else ctrl.with(.i, shift) },
        .reset_zoom => .{ .label = tx.actual_size, .accelerator = ctrl.key(.digit0) },
        .zoom_in => .{ .label = tx.zoom_in, .accelerator = ctrl.key(.plus) },
        .zoom_out => .{ .label = tx.zoom_out, .accelerator = ctrl.key(.minus) },
        .toggle_full_screen => .{ .label = tx.toggle_full_screen, .accelerator = if (mac) ctrl.with(.f, .{ .control = true }) else .{ .key = .f11 } },
        .minimize => .{ .label = tx.minimize, .accelerator = ctrl.key(.m) },
        .zoom => .{ .label = tx.zoom },
        .close => .{ .label = if (context.documents) tx.close else tx.close_window, .accelerator = ctrl.key(.w) },
        .new => .{ .label = tx.new, .accelerator = ctrl.key(.n) },
        .open => .{ .label = tx.open, .accelerator = ctrl.key(.o) },
        .open_recent => .{ .label = tx.open_recent },
        .save => .{ .label = tx.save, .accelerator = ctrl.key(.s) },
        .save_as => .{ .label = tx.save_as, .accelerator = if (mac) ctrl.with(.s, .{ .shift = true, .alt = true }) else ctrl.with(.s, shift) },
        .duplicate => .{ .label = tx.duplicate, .accelerator = if (mac) ctrl.with(.s, shift) else null },
        .rename => .{ .label = tx.rename },
        .move_to => .{ .label = tx.move_to },
        .revert => .{ .label = if (mac) tx.revert_to_saved else tx.revert },
        .quit => switch (context.platform) {
            .macos => .{ .label = tx.quit_app, .accelerator = ctrl.key(.q) },
            .windows => .{ .label = tx.exit },
            .linux => .{ .label = tx.quit, .accelerator = ctrl.key(.q) },
        },
        .about => .{ .label = tx.about },
        .hide => .{ .label = tx.hide, .accelerator = if (mac) ctrl.key(.h) else null },
        .hide_others => .{ .label = tx.hide_others, .accelerator = if (mac) ctrl.with(.h, .{ .alt = true }) else null },
        .unhide => .{ .label = tx.show_all },
        .front => .{ .label = tx.bring_all_to_front },
        .services => .{ .label = tx.services },
        .start_speaking => .{ .label = tx.start_speaking },
        .stop_speaking => .{ .label = tx.stop_speaking },
        .window, .window_menu => .{ .label = tx.window },
        .help => .{ .label = tx.help },
        .app_menu => .{ .label = "{app}" },
        .file_menu => .{ .label = tx.file },
        .edit_menu => .{ .label = tx.edit },
        .view_menu => .{ .label = tx.view },
        .format_menu => .{ .label = tx.format },
        .bold => .{ .label = tx.bold, .accelerator = ctrl.key(.b) },
        .italic => .{ .label = tx.italic, .accelerator = ctrl.key(.i) },
        .underline => .{ .label = tx.underline, .accelerator = ctrl.key(.u) },
        .strikethrough => .{ .label = tx.strikethrough, .accelerator = ctrl.with(.x, shift) },
        .align_left => .{ .label = tx.align_left, .accelerator = if (mac) null else ctrl.key(.l) },
        .align_center => .{ .label = tx.center, .accelerator = if (mac) null else ctrl.key(.e) },
        .align_right => .{ .label = tx.align_right, .accelerator = if (mac) null else ctrl.key(.r) },
    };
}

pub const GroupLabel = enum {
    speech,
    fn text(self: GroupLabel, strings: Strings) []const u8 {
        return switch (self) {
            .speech => strings.speech,
        };
    }
};

pub const Entry = union(enum) {
    role: Role,
    separator,
    /// A submenu without a role of its own, such as Speech.
    group: struct { label: GroupLabel, entries: []const Entry },
};

/// The default entries of a submenu role; empty for other roles. The recent
/// documents of `open_recent` are the application's to add.
pub fn submenu(role: Role, context: Context) []const Entry {
    const mac = context.platform == .macos;
    return switch (role) {
        .app_menu => &.{ .{ .role = .about }, .separator, .{ .role = .services }, .separator, .{ .role = .hide }, .{ .role = .hide_others }, .{ .role = .unhide }, .separator, .{ .role = .quit } },
        .file_menu => if (context.documents)
            if (mac)
                &.{ .{ .role = .new }, .{ .role = .open }, .{ .role = .open_recent }, .separator, .{ .role = .close }, .{ .role = .save }, .{ .role = .duplicate }, .{ .role = .rename }, .{ .role = .move_to }, .{ .role = .revert } }
            else
                &.{ .{ .role = .new }, .{ .role = .open }, .{ .role = .open_recent }, .separator, .{ .role = .save }, .{ .role = .save_as }, .{ .role = .revert }, .separator, .{ .role = .close }, .separator, .{ .role = .quit } }
        else if (mac) &.{.{ .role = .close }} else &.{.{ .role = .quit }},
        .edit_menu => if (mac)
            &.{ .{ .role = .undo }, .{ .role = .redo }, .separator, .{ .role = .cut }, .{ .role = .copy }, .{ .role = .paste }, .{ .role = .paste_and_match_style }, .{ .role = .delete }, .{ .role = .select_all }, .separator, .{ .group = .{ .label = .speech, .entries = &.{ .{ .role = .start_speaking }, .{ .role = .stop_speaking } } } } }
        else
            &.{ .{ .role = .undo }, .{ .role = .redo }, .separator, .{ .role = .cut }, .{ .role = .copy }, .{ .role = .paste }, .{ .role = .delete }, .separator, .{ .role = .select_all } },
        .format_menu => &.{ .{ .role = .bold }, .{ .role = .italic }, .{ .role = .underline }, .{ .role = .strikethrough }, .separator, .{ .role = .align_left }, .{ .role = .align_center }, .{ .role = .align_right } },
        .view_menu => &.{ .{ .role = .reload }, .{ .role = .force_reload }, .{ .role = .toggle_dev_tools }, .separator, .{ .role = .reset_zoom }, .{ .role = .zoom_in }, .{ .role = .zoom_out }, .separator, .{ .role = .toggle_full_screen } },
        .window_menu => if (mac) &.{ .{ .role = .minimize }, .{ .role = .zoom }, .separator, .{ .role = .front } } else &.{ .{ .role = .minimize }, .{ .role = .close } },
        else => &.{},
    };
}

/// Fills caller storage with menu items. Labels are written into `labels`
/// and borrowed by the items, so keep both until the menu is set.
pub const Builder = struct {
    pub const Error = error{ TooManyMenuItems, TextCapacityExceeded, EmbeddedNul, InvalidUtf8 };
    items: []types.Item,
    labels: []u8,
    context: Context,
    count: usize = 0,
    label_bytes: usize = 0,
    next_group_id: u64 = id_base - 1,
    occurrences: std.EnumArray(Role, u8) = .initFill(0),

    pub fn init(items: []types.Item, labels: []u8, context: Context) Builder {
        return .{ .items = items, .labels = labels, .context = context };
    }
    pub fn add(self: *Builder, item: types.Item) Error!void {
        if (self.count == self.items.len) return error.TooManyMenuItems;
        self.items[self.count] = item;
        self.count += 1;
    }
    pub fn separator(self: *Builder, parent: ?u64) Error!void {
        try self.add(.{ .kind = .separator, .parent = parent });
    }
    /// Adds the role's item under `parent`, null for the menu bar. A submenu
    /// role also adds its default entries. Returns the item's ID.
    pub fn role(self: *Builder, parent: ?u64, value: Role) Error!u64 {
        const value_defaults = defaults(value, self.context);
        const label = try self.format(value_defaults.label);
        const occurrence = self.occurrences.get(value);
        if (occurrence == std.math.maxInt(u8)) return error.TooManyMenuItems;
        const item_id = value.occurrenceId(occurrence);
        if (!value.isSubmenu()) {
            // One item owns an accelerator; repeats show none.
            try self.add(.{ .id = item_id, .parent = parent, .label = label, .accelerator = if (occurrence == 0) value_defaults.accelerator else null });
        } else {
            try self.add(.{ .id = item_id, .parent = parent, .kind = .submenu, .label = label });
            try self.entries(item_id, submenu(value, self.context));
        }
        self.occurrences.set(value, occurrence + 1);
        return item_id;
    }
    pub fn entries(self: *Builder, parent: ?u64, list: []const Entry) Error!void {
        for (list) |entry| switch (entry) {
            .role => |value| _ = try self.role(parent, value),
            .separator => try self.separator(parent),
            .group => |group| {
                const group_id = self.next_group_id;
                self.next_group_id -= 1;
                try self.add(.{ .id = group_id, .parent = parent, .kind = .submenu, .label = try self.format(group.label.text(self.context.strings)) });
                try self.entries(group_id, group.entries);
            },
        };
    }
    /// Fills an Open Recent submenu (`parent`, the ID `role(.open_recent)`
    /// returned): an item per document, newest first, labeled with its file
    /// name, then a separator and Clear Menu, which is disabled while there
    /// are none. Map a chosen item back with `recentDocumentIndex`; Clear
    /// Menu is `clear_recent_id`.
    pub fn recentDocuments(self: *Builder, parent: u64, paths: []const []const u8) Error!void {
        for (paths, 0..) |path, index| {
            const name = std.fs.path.basename(path);
            // A file name keeps its ampersands, which menus read as mnemonics.
            var escaped: [512]u8 = undefined;
            var length: usize = 0;
            for (name) |byte| {
                if (length + 2 > escaped.len) return error.TextCapacityExceeded;
                escaped[length] = byte;
                length += 1;
                if (byte == '&') {
                    escaped[length] = '&';
                    length += 1;
                }
            }
            try self.add(.{ .id = recent_document_base + index, .parent = parent, .label = try self.copy(escaped[0..length]) });
        }
        if (paths.len > 0) try self.separator(parent);
        const label = self.context.strings.clear_recent;
        try self.add(.{ .id = clear_recent_id, .parent = parent, .label = try self.format(if (label.len > 0) label else english.clear_recent), .enabled = paths.len > 0 });
    }
    fn copy(self: *Builder, label: []const u8) Error![]const u8 {
        if (self.labels.len - self.label_bytes < label.len) return error.TextCapacityExceeded;
        try menus.validateLabel(label);
        const written = self.labels[self.label_bytes..][0..label.len];
        @memcpy(written, label);
        self.label_bytes += label.len;
        return written;
    }
    pub fn result(self: *const Builder) []const types.Item {
        return self.items[0..self.count];
    }
    fn format(self: *Builder, label: []const u8) Error![]const u8 {
        var writer = std.Io.Writer.fixed(self.labels[self.label_bytes..]);
        var rest = label;
        while (std.mem.indexOf(u8, rest, "{app}")) |index| {
            writer.writeAll(rest[0..index]) catch return error.TextCapacityExceeded;
            writer.writeAll(self.context.app_name) catch return error.TextCapacityExceeded;
            rest = rest[index + "{app}".len ..];
        }
        writer.writeAll(rest) catch return error.TextCapacityExceeded;
        const written = writer.buffered();
        try menus.validateLabel(written);
        self.label_bytes += written.len;
        return written;
    }
};

const testing = std.testing;

test "role labels follow the language and the platform" {
    const zh = resolve("zh-CN", &.{});
    try testing.expectEqualStrings("撤销", defaults(.undo, .{ .strings = zh }).label);
    try testing.expectEqualStrings("復原", defaults(.undo, .{ .strings = resolve("zh_TW.UTF-8", &.{}) }).label);
    try testing.expectEqualStrings("Undo", defaults(.undo, .{ .strings = resolve("de-DE", &.{}) }).label);
    const ja = resolve("ja-JP", &.{});
    try testing.expectEqualStrings("取り消す", defaults(.undo, .{ .strings = ja }).label);
    try testing.expectEqualStrings("{app}を終了", defaults(.quit, .{ .strings = ja, .platform = .macos }).label);
    const custom = resolve("de", &.{.{ .tag = "de", .strings = .{ .undo = "Rückgängig" } }});
    try testing.expectEqualStrings("Rückgängig", defaults(.undo, .{ .strings = custom }).label);
    try testing.expectEqualStrings("Redo", defaults(.redo, .{ .strings = custom }).label);
    try testing.expectEqual(types.Key.y, defaults(.redo, .{ .platform = .windows }).accelerator.?.key);
    const linux_redo = defaults(.redo, .{ .platform = .linux }).accelerator.?;
    try testing.expect(linux_redo.key == .z and linux_redo.modifiers.shift and linux_redo.modifiers.control);
    try testing.expectEqualStrings("Exit", defaults(.quit, .{ .platform = .windows }).label);
    try testing.expect(defaults(.quit, .{ .platform = .windows }).accelerator == null);
    try testing.expectEqual(types.Key.q, defaults(.quit, .{ .platform = .linux }).accelerator.?.key);
    try testing.expectEqualStrings("Close Window", defaults(.close, .{}).label);
    try testing.expectEqualStrings("Close", defaults(.close, .{ .documents = true }).label);
    try testing.expectEqual(Role.zoom_in, Role.fromId(Role.zoom_in.id()).?);
    try testing.expect(Role.fromId(42) == null);
    try testing.expect(Role.fromId(id_base + 200) == null);
    try testing.expectEqual(Role.close, Role.fromId(Role.close.occurrenceId(1)).?);
}

test "macOS roles take Command and the standard macOS shortcuts" {
    const command: types.Modifiers = .{ .super = true };
    const mac: Context = .{ .platform = .macos };
    try testing.expectEqual(types.Accelerator{ .key = .c, .modifiers = command }, defaults(.copy, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .q, .modifiers = command }, defaults(.quit, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .h, .modifiers = command }, defaults(.hide, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .h, .modifiers = .{ .super = true, .alt = true } }, defaults(.hide_others, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .f, .modifiers = .{ .super = true, .control = true } }, defaults(.toggle_full_screen, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .z, .modifiers = .{ .super = true, .shift = true } }, defaults(.redo, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .s, .modifiers = .{ .super = true, .shift = true, .alt = true } }, defaults(.save_as, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .s, .modifiers = .{ .super = true, .shift = true } }, defaults(.duplicate, mac).accelerator.?);
    try testing.expectEqual(types.Accelerator{ .key = .c, .modifiers = .{ .control = true } }, defaults(.copy, .{ .platform = .linux }).accelerator.?);
    try testing.expect(defaults(.hide, .{ .platform = .linux }).accelerator == null);
    var items: [96]types.Item = undefined;
    var labels: [4096]u8 = undefined;
    var builder = Builder.init(&items, &labels, .{ .app_name = "Notes", .platform = .macos, .documents = true });
    inline for (.{ .app_menu, .file_menu, .edit_menu, .format_menu, .view_menu, .window_menu }) |value| _ = try builder.role(null, value);
    _ = try menus.validate(builder.result(), false);
}

test "every role and accelerator validates as a menu item" {
    for ([_]Platform{ .windows, .linux, .macos }) |platform| for (languages) |language| {
        const context: Context = .{ .strings = language.strings.merge(english), .app_name = "Notes", .platform = platform };
        inline for (zio.fields(Role)) |field| {
            const value = defaults(@field(Role, field.name), context);
            try testing.expect(value.label.len != 0);
            if (value.accelerator) |accelerator| try menus.validateAccelerator(accelerator);
        }
    };
}

test "builder writes standard menus that pass menu validation" {
    var items: [64]types.Item = undefined;
    var labels: [2048]u8 = undefined;
    var builder = Builder.init(&items, &labels, .{ .strings = resolve("zh-Hans", &.{}), .app_name = "笔记", .platform = .linux, .documents = true });
    _ = try builder.role(null, .file_menu);
    _ = try builder.role(null, .edit_menu);
    _ = try builder.role(null, .view_menu);
    _ = try builder.role(null, .window_menu);
    try builder.add(.{ .id = 7, .parent = Role.window_menu.id(), .label = "自定义" });
    const plan = try menus.validate(builder.result(), false);
    const control: types.Modifiers = .{ .control = true };
    try testing.expectEqualStrings("文件", builder.result()[0].label);
    try testing.expectEqual(Role.quit.id(), menus.matchAccelerator(builder.result(), &plan, .{ .key = .q, .modifiers = control }).?);
    try testing.expectEqual(Role.zoom_in.id(), menus.matchAccelerator(builder.result(), &plan, .{ .key = .plus, .modifiers = control }).?);

    var mac_builder = Builder.init(&items, &labels, .{ .app_name = "Notes", .platform = .macos });
    _ = try mac_builder.role(null, .app_menu);
    _ = try mac_builder.role(null, .edit_menu);
    _ = try menus.validate(mac_builder.result(), false);
    try testing.expectEqualStrings("About Notes", mac_builder.result()[1].label);
    var found_speech = false;
    for (mac_builder.result()) |item| if (std.mem.eql(u8, item.label, "Speech")) {
        found_speech = item.kind == .submenu;
    };
    try testing.expect(found_speech);

    var small: [2]types.Item = undefined;
    var tiny = Builder.init(&small, &labels, .{});
    try testing.expectError(error.TooManyMenuItems, tiny.role(null, .edit_menu));
    var short = Builder.init(&items, labels[0..3], .{});
    try testing.expectError(error.TextCapacityExceeded, short.role(null, .edit_menu));
}

test "open recent lists the documents by file name, then clear menu" {
    var items: [16]types.Item = undefined;
    var labels: [512]u8 = undefined;
    var builder = Builder.init(&items, &labels, .{ .strings = resolve("zh-CN", &.{}) });
    const recent = try builder.role(null, .open_recent);
    try builder.recentDocuments(recent, &.{ "/home/a/notes.md", "/home/a/R&D.txt" });
    const built = builder.result();
    try testing.expectEqual(5, built.len);
    try testing.expectEqualStrings("notes.md", built[1].label);
    try testing.expectEqualStrings("R&&D.txt", built[2].label);
    try testing.expectEqual(@as(?usize, 1), recentDocumentIndex(built[2].id));
    try testing.expect(built[3].kind == .separator);
    try testing.expectEqualStrings("清除菜单", built[4].label);
    try testing.expect(built[4].enabled and built[4].id == clear_recent_id);
    try testing.expectEqual(@as(?Role, null), Role.fromId(built[1].id));
    try testing.expectEqual(@as(?usize, null), recentDocumentIndex(Role.open.id()));
    _ = try menus.validate(built, false);

    var empty = Builder.init(&items, &labels, .{});
    try empty.recentDocuments(try empty.role(null, .open_recent), &.{});
    try testing.expectEqual(2, empty.result().len);
    try testing.expect(!empty.result()[1].enabled);
}
