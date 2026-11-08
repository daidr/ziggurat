# 菜单、托盘与桌面 API

桌面集成都在 `ziggurat_system` 中，按需导入。它们不占用窗口的内容：菜单、上下文菜单、消息框、文件选择器、全局快捷键和通知挂在窗口的 `system.Owner` 上，托盘、剪贴板、拖放等是独立的对象。所有调用和回调都在主线程；需要阻塞系统调用的工作放在应用自己的线程。

```zig
const system = @import("ziggurat_system");

const State = struct {
    owner: system.Owner = undefined,

    fn onOwner(context: *anyopaque, _: z.Window, action: system.Action) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (action) {
            .menu => |id| self.command(id),
            .popup => |result| if (result.selected) |id| self.command(id),
            .hotkey => |id| self.hotkey(id),
            .message => |result| self.answered(result),
            .notification_activated => |id| self.notificationClicked(id),
            else => {},
        }
    }
};

state.owner = system.Owner.init(&state, State.onOwner);
try state.owner.attach(window); // Owner 与 context 保持稳定地址直到窗口 on_closed
```

各项能力在不同平台的支持情况由 `system.capabilities` 报告；未实现时返回 `UnsupportedCapability`。完整说明见 [系统工具](../system.md)。

## 菜单栏

```zig
try owner.setMenu(&.{
    .{ .id = 1, .kind = .submenu, .label = "&File" },
    .{ .id = 2, .parent = 1, .label = "&Open…", .accelerator = .{ .key = .o, .modifiers = .primary } },
    .{ .id = 3, .parent = 1, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = .primary } },
    .{ .parent = 1, .kind = .separator },
    .{ .id = 4, .parent = 1, .label = "E&xit" },
    .{ .id = 10, .kind = .submenu, .label = "&View" },
    .{ .id = 11, .parent = 10, .label = "Word Wrap", .checked = true },
});
try owner.setItemState(11, true, false); // 启用、取消勾选
```

- `setMenu` 事务式替换整个菜单栏；失败保留原菜单。命令选中后以 `Action.menu: u64` 报告。
- `radio = true` 的相邻项组成单选组；`icon` 给菜单项加图标（`system.MenuIcon.fromPng`）。
- `.modifiers = .primary`（`Modifiers.primary`）在 macOS 是 Command，其他平台是 Control。
- macOS 只有一条应用菜单栏，第一个顶层子菜单显示为应用名菜单。用 `menu_roles` 生成标准的应用、编辑、窗口菜单，AppKit 自己执行撤销、拷贝、粘贴等标准角色。

## 上下文菜单与消息框

```zig
try owner.popupMenu(7, &.{
    .{ .id = 1, .label = "&Copy" },
    .{ .kind = .separator },
    .{ .id = 2, .label = "Delete", .enabled = can_delete },
}, .{ .client = point }); // 也可以 .pointer 或 .screen

try owner.showMessage(3, .{
    .title = "未保存",
    .message = "关闭前保存更改？",
    .buttons = &.{ .{ .id = 1, .label = "保存" }, .{ .id = 2, .label = "不保存" }, .{ .id = 3, .label = "取消" } },
    .default_button = 0,
    .cancel_button = 2,
});
```

两者都立即返回，不运行嵌套消息循环。结果分别以 `Action.popup`（`selected` 为 null 表示未选择）和 `Action.message` 交付一次。声明式视图里也可以用视图自己的菜单与对话框，见 [控件速查](../ui/components.md#菜单与浮层)。

## 文件选择器

```zig
try owner.openFiles(.{}, &paths_buffer, &state, onPicked);
try owner.saveFile(.{ .extensions = &.{".txt"}, .suggested_name = "report" }, &path_buffer, &state, onPicked);

fn onPicked(context: *anyopaque, _: z.Window, result: system.picker.Result) void {
    switch (result) {
        .selected => |path| open(path),
        .selected_multiple => |paths| for (paths) |path| open(path),
        .cancelled => {},
        else => {},
    }
}
```

选择器是异步的，路径写进调用者提供的缓冲。

## 托盘

窗口自己的托盘用 `owner.setTray`；不依附窗口的托盘用独立的 `system.Tray`，它可以有自己的菜单：

```zig
state.tray = system.Tray.init(&state, onTray);
try state.tray.show(app, .{
    .tooltip = "Clipper",
    .title = "Clipper",
    .menu = &.{
        .{ .id = 1, .label = "Show" },
        .{ .id = 2, .label = "Quit" },
    },
});
```

只活在通知区的应用设置 `AppOptions.on_all_windows_closed`，使 App 在没有窗口时继续运行。点击托盘图标打开一个面板，用 [浮出窗口](#浮出窗口)。Linux 托盘需要会话总线上的 status-notifier 宿主。

## 全局快捷键与通知

```zig
try owner.registerHotkey(1, .{ .key = .space, .modifiers = .{ .control = true, .shift = true } });
try owner.showNotification(2, .{ .title = "完成", .body = "导出完成" });
```

快捷键按下时报告 `Action.hotkey`，用户点击通知时报告 `Action.notification_activated`。Linux 的全局快捷键只在 X11 上可用；macOS 通知需要应用包。仓库中的 `examples/launcher.zig` 是一个用全局快捷键唤出的启动器。

## 剪贴板与拖放

- `system.clipboard.Board` 连接系统剪贴板：写入纯文本、HTML、文件列表或自定义格式，**延迟提供**（只在别的程序粘贴时才生成内容），按格式读取，以及变化通知。`writeTextThen` 在所有平台异步写入文本；同步的 `writeText`/`readText` 只在 Windows 与 macOS 提供。
- `system.drop.Target` 把窗口注册为放置目标，`on_hover` 报告进入、经过、离开与对方提供的类型，`on_drop` 交付文件路径或文本。`system.drag.Source` 从应用拖出数据。
- 声明式视图内的拖放用 `View.dragSource` 与 `View.dropTarget`，见 [声明式视图](../view.md#拖动与拖放)。

示例：`examples/clipboard.zig`、`examples/drag_drop.zig`。

## 浮出窗口

`system.Flyout` 是一个锚定在窗口、矩形或托盘图标旁的弹出窗口，拥有自己的 `view.Host`。它接收键盘，点到别处或按 Escape 时关闭，超出屏幕时翻转或滑动：

```zig
var host = view.Host.init(&state, build, buffers, .{ .fit_content = .{
    .context = &panel, .widths = system.Flyout.contentWidths, .tell = system.Flyout.contentSized,
} });
_ = try panel.open(app, .{
    .anchor = .{ .tray = &tray },
    .hidden = true,
    .fit_content = .{ .min_width = 260, .max_height = 480 },
    .measure = .{ .context = &host, .call = view.Host.fitNow },
});
try host.attach(panel.window.?);
panel.show();
```

示例：`examples/flyout.zig`、`examples/menubar_flyout.zig`。

## 系统外观与桌面环境

- `system.theme.Follower` 决定应用的明暗外观：`.system` 跟随桌面，`.light`/`.dark` 强制，外观或偏好变化时回调。
- `system.desktop` 读取显示器、偏好（强调色、配色、减少动态与透明、高对比度、文字缩放）、电源与网络状态的快照，并订阅变化，见 [桌面环境](../desktop-environment.md)。

## 更多系统设施

| 能力 | 入口 | 文档 |
| --- | --- | --- |
| 打开 URL、在文件管理器中显示、移到废纸篓、启动程序 | `system.OpenUrl`、`shell.Worker`（后台线程） | [系统工具](../system.md#显式后台-shell-工作) |
| 密钥存储 | `system.secrets`（Credential Manager、Secret Service、钥匙串） | [系统工具](../system.md#密钥存储) |
| 最近文档、Jump List、重启 | `system.recent` | [系统工具](../system.md#最近文档、jump-list-与重启) |
| 文件监视 | `system.watch.Watcher`（后台线程） | [文件监视](../file-watch.md) |
| 系统权限检查与设置引导 | `system.permissions` | [系统工具](../system.md#系统权限与设置引导) |
| Now Playing 与媒体键 | `system.NowPlaying` | [系统工具](../system.md#now-playing-与媒体键) |
| 单实例、深链、文件关联、登录启动、阻止休眠、任务栏进度 | `system.instance`、`integration`、`power`、`taskbar` | [单实例与系统集成](../os-integration.md) |
