# 系统工具

按需导入 `ziggurat_system`。应用身份、系统目录、单实例与参数转发、登录启动、URL scheme/文件关联、阻止休眠和任务栏状态见 [单实例与系统集成](os-integration.md)。原生菜单栏、菜单快捷键、上下文菜单、异步消息框、窗口托盘、独立托盘、异步文件选择器、全局快捷键和通知实现 Windows 和 Linux；同步文本剪贴板 helper 目前仅 Windows；多格式剪贴板 Board、放置目标、桌面环境快照/订阅、粗模式文件监视、密钥存储和浮出窗口支持 Windows/Linux。`system.capabilities` 分别报告编译目标的支持状态，未实现的窗口扩展返回 `UnsupportedCapability`。Linux 的托盘与通知走会话总线，全局快捷键只在 X11 上可用，运行时缺少对应服务或显示协议时按下文各节明确报告。独立的无 UI `shell.Worker` 已支持 Windows/Linux 显式程序启动，以及 Windows 有界文件图标，能力见 `system.capabilities.shell`。

## 窗口 owner

`Owner.init(context, on_action)` 返回值对象，再用 `try owner.attach(window)` 挂载。附加后的 Owner 不可移动或复制；它与业务 context 保持稳定地址直到 `on_closed`。所有调用和业务回调都在进程主线程。

每个窗口只有一个 `WindowService`，Owner 在其中组合菜单、托盘、选择器、快捷键和通知，不占用 `Content`。窗口原生销毁时先清除 service 入口，再撤销选择器等待、注销快捷键、移除通知和托盘、释放菜单和图标。`try owner.detach()` 可提前移除服务；它不会 detach UI/WebView 内容。重复 detach 无副作用。

原生消息中的命令 ID 来自窗口的 `reserveNativeIds`，在该 HWND 生存期内不复用，包括换 Owner、替换菜单和失败配置。耗尽返回 `IdExhausted`，不会把旧消息投递给新动作。框架不保留全局业务回调表。

Linux 上每个原生记录（菜单栏、弹出菜单、对话框、选择器、托盘项、通知、按键抓取）只持有一个不透明 owner 标记和自己的引用计数；Owner detach 或窗口关闭先清除该标记，迟到的 GTK 信号、总线回复或 X 事件只释放记录本身。每次请求都带 Owner 内单调递增的序号，替换后的旧记录不会命中新请求。

## 菜单

`setMenu([]const system.Item)` 事务式替换原生菜单栏。每项有 `id: u64`、`label`、`kind`、`parent`、`enabled` 和 `checked`；kind 是 `command`、`submenu` 或 `separator`。非分隔项 ID 非零且唯一，parent 必须指向切片中更早声明的 submenu。null parent 表示菜单栏根。

```zig
try owner.setMenu(&.{
    .{ .id = 1, .kind = .submenu, .label = "&File" },
    .{ .id = 2, .parent = 1, .label = "&Save" },
    .{ .parent = 1, .kind = .separator },
    .{ .id = 3, .parent = 1, .label = "E&xit" },
});
```

标签只借用到 `setMenu` 返回，由系统复制；最多 128 项，每个标签最多 255 个 UTF-16 单元。配置失败保留原菜单；已经预留的原生命令 ID 不回退。选择命令产生 `Action.menu: u64`，禁用命令不调用业务回调。

`radio = true` 的命令项显示单选标记而不是勾选标记：同一 parent 下相邻的单选命令组成一组，组内最多一项 checked（否则 `MultipleRadioChecked`），非命令项不能是单选（`InvalidRadioItem`）。`setItemState` 勾选单选项时同组其余项取消勾选；状态与勾选项一样由应用保存，用户选择只产生 `Action.menu`。Windows 用 `MFT_RADIOCHECK` 与 `CheckMenuRadioItem`，GTK 用画成单选样式的 `GtkCheckMenuItem`，未勾选时也显示空的单选圈。

`setItemState(id, enabled, checked)` 更新命令项；submenu 状态变化用新的 `setMenu` 快照。`clearMenu()` 移除菜单栏。禁用的 submenu 使其下所有命令（含快捷键）失效。

### 菜单项图标

命令项和 submenu 可以带 `icon`，显示在标签前，比如 VPN 托盘菜单里每个服务器的旗帜。`system.MenuIcon.fromPng(app, png, .{})` 从 PNG 字节做一个图标，非 PNG 返回 `InvalidPng`；每个图标做一次，给任意多个菜单项用。分隔符不能带图标（`InvalidMenuIcon`）。

```zig
var japan = try system.MenuIcon.fromPng(app, japan_png, .{});
defer japan.deinit();
try tray.show(app, .{ .icon = icon.handle(), .tooltip = "VPN", .menu = &.{
    .{ .id = 1, .label = "Tokyo", .radio = true, .checked = true, .icon = &japan },
    .{ .id = 2, .label = "Osaka", .radio = true, .icon = &japan },
    .{ .id = 3, .label = "Direct", .radio = true },
} });
```

图标按原比例放进 16×16 DIP 的方框，按菜单所在显示器的缩放生成；给 32×32 或 48×48 像素以上的图，150% 和 200% 缩放下才清晰。勾选和单选项仍显示勾选标记。`owner.setItemIcon(id, &icon)` 替换菜单栏里命令项的图标，null 去掉。`.template = true` 的模板图是黑色加透明，在 Windows 上取菜单文字颜色（深色菜单为白色）；GTK 按原样显示。菜单只借用图标：MenuIcon 要在没有菜单再显示它之后才 `deinit`。

- **Windows**：图标是菜单项的位图（`hbmpItem`），32 位预乘 alpha 的 DIB section，每种尺寸和颜色只生成一次，归 MenuIcon 所有；位图画在勾选标记那一列，勾选的项显示带勾选框的图标而不是勾。菜单栏自身的项不显示图标。
- **Linux**：菜单栏的下拉菜单和上下文菜单（GTK）在标签前放一个 `GtkImage`，菜单栏自身的项不显示。托盘菜单由面板绘制，图标通过 DBusMenu 的 `icon-data` 发送 PNG：GNOME Shell 的 AppIndicator 扩展和 KDE Plasma 会显示，其他面板可能不显示。

Linux 菜单栏是 `GtkMenuBar`。附加时平台层把窗口原有子控件（绘制区或内容宿主）移进一个纵向 `GtkBox`，菜单栏在上；`clearMenu`、detach 时移回原位，并重新实现绘制区、重新绑定输入法。替换快照时新菜单栏先占位再销毁旧菜单栏。客户区和内容尺寸不含菜单栏高度。命令激活与快捷键都在一次性 idle 中报告，不在 GTK 信号发射期间调用业务代码；带勾选的项是 `GtkCheckMenuItem`，GTK 激活时自行切换的勾选状态会被还原，状态只由 `setItemState` 决定。

菜单栏、上下文菜单和托盘菜单共用同一套校验（`system.menus.validate`）：标签不得含 NUL 或非法 UTF-8；`&` 标记助记符，`&&` 表示字面 `&`，在 GTK 上自动转换为 `_` 形式。

## 菜单快捷键

命令项可以设置 `accelerator = .{ .key = .s, .modifiers = .{ .control = true } }`。字母、数字、空格和导航键必须带 Control、Alt 或 Super，避免普通输入触发命令；F1–F24 可以单独使用。快捷键只能用于 command 项，同一快照内不能重复，违反时 `setMenu` 返回 `InvalidAccelerator` 或 `DuplicateAccelerator` 并保留原菜单。

菜单显示系统风格的快捷键文字（Windows 为 `Ctrl+Shift+S`，GTK 由系统按键标签绘制）。Windows 菜单栏会分发快捷键：窗口 Content 的 `key_input` 未消费的 `WM_KEYDOWN`/`WM_SYSKEYDOWN` 匹配到启用的命令时产生 `Action.menu: u64` 并消费该键；自动重复、AltGr 文本输入、禁用命令及禁用祖先下的命令都不触发。旧版编辑键路径（Ctrl+C 等）在 Content 没有 `key_input` 时位于服务之后，所以同一组合同时绑定为快捷键时由菜单先处理。Linux 菜单栏同样只分发 Content 未消费的键：GTK 先把按键交给窗口的焦点控件，之后才轮到菜单栏的匹配；匹配到启用的命令时消费该键并产生 `Action.menu`。快捷键只用于显示，不注册到 GTK 加速键组，所以不会抢在 Content 之前触发。菜单栏的 `Alt` 助记符和 F10 仍按 GTK 规则先于 Content 处理。平台旧版编辑键路径（Ctrl+A/C/X/V/Z/Y）在 Content 不消费时会先映射成编辑命令，这些组合在 Linux 上不会再到达菜单栏。上下文菜单中的快捷键只显示，不分发。

## 上下文菜单

`popupMenu(request, items, anchor)` 在调用返回后打开一个上下文菜单。`request` 是非零业务 ID；`items` 与菜单栏格式相同，至少一项；标签在返回前复制。`anchor` 为 `.pointer`（当前指针）、`.client`（窗口客户区 DIP 坐标）或 `.screen`（屏幕物理像素）。

```zig
try owner.popupMenu(7, &.{
    .{ .id = 1, .label = "&Copy", .accelerator = .{ .key = .c, .modifiers = .{ .control = true } } },
    .{ .kind = .separator },
    .{ .id = 2, .label = "Delete", .enabled = can_delete },
}, .{ .client = point });
```

每个 Owner 同时只有一个待处理菜单，重复请求返回 `MenuAlreadyPending`。每个被接受的请求只完成一次：`Action.popup = .{ .request = 7, .selected = 1 }`，关闭而未选择时 `selected = null`。`cancelPopup()` 关闭菜单，请求仍以 null 完成。detach 或窗口关闭则不再调用业务回调。只会报告启用且所有祖先都启用的命令。

Windows 不在调用者的栈上运行菜单：请求投递到一个私有隐藏窗口，在主循环分发到它时才调用 `TrackPopupMenuEx`。系统菜单跟踪循环与原生移动/缩放循环相同，期间 `App.post` 任务照常执行，`watchNative` 等待在菜单关闭后才触发。若另一个菜单或移动/缩放循环已经在运行，新请求不叠加第二层循环，直接以 null 完成。隐藏窗口指回 Owner 的链接在 detach 时先切断，因此迟到返回的跟踪循环只释放自己的菜单和窗口。

Linux 使用 GTK `gtk_menu_popup_at_rect`，不运行嵌套主循环；完成在一次性 idle 回调中报告，不在 GTK 信号发射期间调用业务代码。菜单无法取得输入抓取而没有打开时以 null 完成。窗口必须已映射，否则返回 `MenuStartFailed`。`.client` 坐标相对内容区域，窗口有菜单栏时不含菜单栏高度。

## 异步消息框

`showMessage(request, options)` 显示消息框并立即返回。`options` 含 `title`、`message`（非空，最多 4096 个 UTF-16 单元）、1–3 个 `buttons`（非零唯一 ID 与非空标签）、可选的 `default_button`/`cancel_button` 下标，以及 `kind`（info/warning/err/question）。

```zig
try owner.showMessage(3, .{
    .title = "未保存",
    .message = "关闭前保存更改？",
    .buttons = &.{ .{ .id = 1, .label = "保存" }, .{ .id = 2, .label = "不保存" }, .{ .id = 3, .label = "取消" } },
    .default_button = 0,
    .cancel_button = 2,
});
```

结果只交付一次 `Action.message = .{ .request, .response }`。`response` 为 `.button: u64`、`.dismissed` 或 `.failed { err, code }`。Escape 或关闭按钮在指定 `cancel_button` 时报告该按钮，否则为 `dismissed`；`cancelMessage()` 总是以 `dismissed` 完成。同一 Owner 同时只有一个消息框，重复请求返回 `MessageAlreadyPending`。detach 或窗口关闭撤销等待且不调用业务回调。

Windows 使用系统 `Windows.UI.Popups.MessageDialog` 的异步接口与 HWND 初始化，和文件选择器相同：原生完成只触发独立内核事件，App 的单次原生等待在主线程读取结果，不创建线程或嵌套消息循环。该接口最多三个按钮且不显示图标，`kind` 在 Windows 上不改变外观；其模态与焦点行为由系统决定。原生状态不持有 Zig 或 App 指针，`system.message.resourceCount()` 统计它们。

Linux 使用模态、`transient-for` 父窗口的 `GtkMessageDialog`，通过 `response` 信号报告，不调用 `gtk_dialog_run`。GTK 模态作用于父窗口所在的窗口组；父窗口销毁时对话框随之销毁。`system.message.resourceCount()` 统计尚存的原生菜单、对话框、选择器、托盘、通知和按键抓取记录，包括 Owner 已 detach、仍等待 GTK 或总线完成的记录；App 停止后不再运行的完成回调不会再把它降到零。

## 托盘

`setTray(.{ .icon = borrowed_hicon, .tooltip = "工具" })` 创建或替换一个托盘项。icon 为 null 时复制系统默认应用图标；传入图标只在调用期间借用，Owner 持有独立 `CopyIcon` 结果。tooltip 复制到固定存储，最多 127 个 UTF-16 单元。`clearTray()` 删除图标并释放本地图标句柄。

使用 `NOTIFYICON_VERSION_4`。激活产生 `Action.tray_activate`；右键或键盘菜单请求产生 `Action.tray_context: ScreenPoint`，坐标是屏幕像素。应用决定如何显示自己的菜单或窗口。Owner 接收 `TaskbarCreated` 后重建自己的托盘项；失败通过窗口诊断 sink 报告。附加期间保留窗口消息 `WM_APP + 0x421`。[系统通知区协议](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw)

Linux 托盘项是会话总线上的 status notifier item：每项在自己的对象路径导出 `org.kde.StatusNotifierItem`，并在 `org.kde.StatusNotifierWatcher` 出现时（包括面板重启后）登记该路径。`icon` 是借用的 `GdkPixbuf`（RGB/RGBA、8 位、最大 1024×1024），调用期间复制成协议要求的 ARGB；null 使用图标名 `application-x-executable`。再次 `setTray` 原地替换图标和提示并通知宿主重读。宿主调用 `Activate` 产生 `tray_activate`，`ContextMenu(x, y)` 产生 `tray_context`，坐标是宿主报告的屏幕坐标。项不导出 dbusmenu 菜单，菜单由应用自己的弹出菜单显示；只认 dbusmenu 的宿主不会显示该菜单。

总线连接、导出和登记都是异步的：`setTray` 只同步校验并复制参数，连接失败、导出失败或 watcher 拒绝登记都通过窗口诊断 sink 以 `dbus` 域报告（`TrayCreationFailed`/`TrayRegistrationFailed`，code 为 GIO 错误码）。没有 watcher 时项保持导出但不可见，watcher 出现后自动登记。GIO 的总线连接使用 GLib 自身的 I/O 线程，所有回调都回到主线程。

## 独立托盘

`system.Tray` 属于 App 而不是窗口，可以同时存在多个。`var tray = system.Tray.init(context, on_action)` 后用 `try tray.show(app, .{ .tooltip = "工具" })` 创建，再次 `show` 原地替换图标和提示。Tray 从 show 到 remove 或 App 停止期间保持稳定地址；每个 Tray 有自己的隐藏顶层窗口、复制的图标和一个 App 停止登记，所以忘记 `remove()` 时 App 停止也会移除图标。`remove()` 可重复调用，之后可以再次 show，并使用新的原生 ID，旧回调消息不会命中新图标。

`TrayItemOptions.guid` 可选，按标识符文字的字节顺序给出 16 字节。系统据此跨运行记住用户摆放的位置；它绑定到当前可执行文件路径，换路径后添加会失败。设置后不能在同一次显示中更换（`TrayIdentityChanged`）。

回调为 `on_action(context, *Tray, TrayAction)`：`.activate`（单击或键盘选择）、`.context: ScreenPoint`（右键或菜单键，屏幕像素）和 `.popup: PopupResult`。在 `.context` 中调用 `tray.popupMenu(request, items, .icon)` 打开锚定菜单：`.icon` 使用系统报告的图标矩形并避开遮挡图标，取不到时用指针位置；也可传 `.pointer` 或 `.screen`。打开前隐藏窗口取得前台，菜单在外部点击时关闭；完成语义与窗口上下文菜单相同。任务栏重建时 Tray 重新添加图标。Tray 使用回调消息 `WM_APP + 0x422`。

Linux 独立托盘与窗口托盘使用同一 status notifier item 实现，`guid` 以 32 位十六进制写入项的 `Id`，供记住摆放位置的宿主使用。宿主的 `Activate`/`ContextMenu` 坐标同时记为 `.icon` 锚点；宿主不报告图标矩形，没有记录时 `.icon` 退回指针位置。弹出菜单需要一个已映射的 GDK 窗口作锚点，独立托盘在 X11 上于该点创建 1×1 的 override-redirect 窗口，菜单完成后销毁；Wayland 不允许无父表面的弹出菜单，返回 `MenuStartFailed`。失败诊断通过 `App.report` 报告。

## 全局快捷键

`registerHotkey(id, .{ .key = .f24, .modifiers = .{ .control = true, .shift = true } })` 在 Owner 的 HWND 注册系统级快捷键。业务 ID 非零，同一 Owner 内唯一，最多同时 32 项。Key 是字母、数字、F1–F24 及常用导航键的命名枚举，修饰键为 control/alt/shift/super；默认禁止按住自动重复，可显式设置 `repeat = true`。Windows 保留 F12，因此注册它返回 `UnsupportedKey`。

原生注册冲突返回 `HotkeyRegistrationFailed`，原始系统码保留在 `owner.last_error`；失败不占活动槽位。收到有效消息产生 `Action.hotkey: u64`。`unregisterHotkey(id)` 移除一项，未知 ID 返回 `HotkeyNotFound`；`clearHotkeys()` 移除全部。detach/窗口关闭也主动注销。每次注册使用新的窗口原生 ID，已经移除或上一个 Owner 的排队消息不会调用新动作。Windows 要求快捷键 ID 不超过 `0xBFFF`，本窗口的 ID 区间耗尽时返回 `IdExhausted`，不会绕回复用。原生注册规则见 [RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)。

Linux 在 X11 根窗口上用 `XGrabKey` 抓取按键，对 CapsLock/NumLock 的四种组合分别抓取，因此锁定键状态不影响匹配；super 对应 Mod4。其他客户端已经抓取同一组合时，X 服务器以错误拒绝，返回 `HotkeyRegistrationFailed`，X 错误码在 `owner.last_error`；同一进程内重复注册同一组合同样被拒绝。检测冲突需要一次 X 往返（错误陷阱的同步），这是对 X 服务器的协议请求，不等待应用工作。按键在根窗口事件过滤器中匹配、在 idle 中报告；不允许重复时，同一键在松开前只报告一次（进程启用 X 的可检测自动重复）。没有对应键码的键（例如部分 F13–F24 布局）返回 `UnsupportedKey`。Wayland 等非 X11 显示返回 `UnsupportedCapability`：桌面全局快捷键门户需要用户授权会话，当前未实现。

## 通知区通知

`showNotification(id, .{ .title = "完成", .body = "导出完成" })` 向 Windows Shell 提交一条通知区通知。业务 ID 非零、body 非空；title/body 分别最多 63/255 个 UTF-16 单元，超长或非法文本返回错误，保留原通知。kind 为 info/warning/err，默认 silent 和 real_time 为 true，系统不能立即显示时丢弃。每个 Owner 同时保留一条通知，使用独立复制图标，不需要配置持久托盘项。成功替换采用新的原生 ID；通知文本在调用中交给系统复制，不保留调用者切片。

点击产生 `Action.notification_activated: u64`，在调用业务回调前删除对应 Shell 项并释放图标。hide/timeout 只清理，不调用业务动作。`clearNotification()`、detach 和窗口关闭均回收通知；任务栏重建后不重播过时消息。晚到通知事件只匹配其原始 ID。

这是 [NIF_INFO 通知区接口](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw)，不提供现代 Toast 的 action buttons、通知历史或送达保证。调用成功只证明 Shell 接受提交；系统设置、专注模式、用户操作等决定实际展示。

Linux 调用会话总线上的 `org.freedesktop.Notifications.Notify`，带一个 `default` 动作；文本限制与 Windows 相同。kind 映射为 urgency（info/warning 为普通，err 为紧急），silent 映射为 `suppress-sound`，real_time 映射为 `transient`（不进入通知历史）。提交在调用返回后异步完成：`showNotification` 只同步校验并复制文本，服务器拒绝或总线不可用时清除该通知并以 `dbus` 域诊断报告 `NotificationSubmissionFailed`。`ActionInvoked(id, "default")` 产生 `notification_activated`，之前先撤回该通知；`NotificationClosed` 只清理。信号只匹配本条通知自己的 `Notify` 回复给出的服务器 ID。替换或清除时已经显示的通知以 `CloseNotification` 撤回；总线尚未连上就被替换的通知不会发送。

## 剪贴板

`system.clipboard.writeText(window, utf8)` 和 `readText(window, destination)` 仍是 Windows 同步文本 helper：容量不足、文本无效或剪贴板被占用时返回错误，不重试或等待。完整剪贴板服务是 `clipboard.Board`。

`try board.init(app, .{ .context, .on_changed, .render_on_stop })` 在 App owner 线程原地初始化，地址稳定到 `deinit`，必须早于 `App.deinit` 结束；初始化失败不留下需要 deinit 的状态。Board 注册 App stop 节点：停机时取消所有 pending 读取（不回调）并结束 lazy offer。不可在 Board 自己的回调中 deinit。所有调用和回调都在 owner 线程。

格式为 `text`、`html`、`png`、`files` 与 `custom`，字节约定跨平台一致：text/html 为无 NUL 的 UTF-8；png 是完整 PNG 流；files 是绝对 UTF-8 路径，单个 NUL 分隔、无结尾分隔，最多 1024 项（`clipboard.paths`/`joinPaths` 辅助）；custom 为不透明字节，名称为 1–100 个可见 ASCII，作为 Windows 注册格式名和 GTK selection target。每项最多 64 MiB，一次最多 16 种格式且不可重复。

`board.write(entries)` 先校验全部条目并在打开剪贴板前构造所有原生块，再在一个事务中替换内容：Windows 依次交给 `SetClipboardData`，任一失败清空而不留下部分内容；HTML 使用 CF_HTML 头和片段偏移，files 写 `CF_HDROP`（`/` 规范为 `\`），png 写注册格式 `PNG`，文本只写 `CF_UNICODETEXT`。GTK 把条目复制进原生 offer，文本发布全部文本 target，files 发布 `text/uri-list` 与 `x-special/gnome-copied-files`。eager offer 在 Board 关闭后继续以自身副本服务，直到其他 owner 取代；进程退出后数据是否保留取决于桌面剪贴板管理器。Windows 剪贴板被其他进程打开时 write 返回 `ClipboardBusy` 并在 `last_error` 保留原生码；是否以及何时重试由调用者显式安排。

`board.offer(provider, formats)` 只宣布格式，读取方请求时才在 owner 线程调用 `provider.render(context, format, sink)`；`sink.set(bytes)` 按同一约定校验并立即复制，每次 render 只能 set 一次，失败或未 set 时该读取方得不到此格式。`released` 在 offer 结束时恰好调用一次：其他 owner 接管、write/offer/revoke 取代或 Board 停止；provider context 必须保持到 released 返回。Windows 使用 Board 私有 message-only HWND 处理 `WM_RENDERFORMAT`/`WM_DESTROYCLIPBOARD`；`render_on_stop = true`（默认）时停止阶段经 `WM_RENDERALLFORMATS` 渲染仍宣布的格式，使数据在进程退出后保留，false 则清空自己仍拥有的 offer。GTK 的 lazy offer 在 Board 关闭时清除，不在停机时调用阻塞的 `gtk_clipboard_store`。`revoke()` 幂等；Windows 剪贴板正被占用时无法清空，宣布的格式此后读取为空。

读取全部异步：`board.read(&request, format, destination, context, on_result, options)` 与 `board.formats(&request, context, on_result)`。Request 是调用者持有的槽，pending 期间地址稳定；结果从不在启动调用内到达，回调前槽已恢复 idle，可在回调中复用。`request.cancel()`、Board deinit 与 App stop 立即释放槽和 destination，之后不再回调。Result 为 `data`（借用 destination）、`formats`（text/html/png/files 是否可用）、`unavailable`、`capacity_exceeded: usize`（不写入任何字节）或 `failed { err, code }`。Windows 用一次 `OpenClipboard` 会话读完所有就绪请求，关闭剪贴板后才按请求顺序回调；被其他进程占用时用 Board HWND 的原生 timer 做至多 `attempts`（默认 4、上限 16）次、间隔 `interval_ms` 的有界重试，耗尽后报告 `ClipboardBusy` 和原生码，不 sleep、不嵌套消息循环。外来 HGLOBAL 可能含分配器填充：text/html 截到终止符、png 截到 IEND，custom 按 `GlobalSize` 原样返回。GTK 使用异步 request API；本进程自己拥有 selection 时 GTK 同步应答，结果被复制后由 idle source 交付。HTML 可能是带 BOM 的 UTF-16，会转为 UTF-8；png 无 `image/png` 时经 GdkPixbuf 转成 PNG；files 只返回本地 `file:` URI，非 UTF-8 路径报告 `ClipboardMalformed`。

`on_changed` 报告任意 owner 变化（包括本 Board 的写入），不附带内容：Windows 使用 `AddClipboardFormatListener`，GTK 使用 `owner-change`。`clipboard.resourceCount()` 统计 Linux 仍存活的 Board/offer/read 原生记录，包括取消后等待 GTK 回调的请求。

## 拖放

`system.drop.Target` 为一个窗口注册原生放置目标：`.{ .context, .on_drop, .on_hover, .kinds, .buffer }` 后 `try target.attach(window)`，地址和 context 保持到 `detach` 或窗口 `on_closed`。kinds 选择 files 和/或 text；`on_hover(context, window, Hover)` 返回是否接受，null 表示接受所提供的已选种类。每段悬停以 enter/over 开始、以 leave 结束，leave 也先于 `on_drop`（GTK 本身如此，Windows 显式对齐）。坐标为客户区 DIP。Drop 的 payload 为 files（剪贴板相同的 NUL 分隔约定）或 text，只在 on_drop 期间借用调用者 buffer；更大的 payload 报告 `capacity_exceeded` 所需字节，不部分发布。接受时报告 copy 效果。

Windows 在 attach 时嵌套 `OleInitialize` 并 `RegisterDragDrop` 一个引用计数的原生 `IDropTarget`，使用 `CF_HDROP`/`CF_UNICODETEXT`；窗口 subclass 在 `WM_DESTROY` 撤销注册，晚到的 OLE 引用只访问已经脱离 Zig 的原生记录。GTK 在顶层 GtkWindow 上以手动放置站点替换其自带的 root-window 站点（自带站点的默认 motion/drop 处理会在 `drag-motion` 前拒绝其他 target，并再次请求数据），列表沿用原有 target 再加上 uri/text，detach 时还原；解析 `text/uri-list` 的本地路径和文本；内容区坐标扣除客户端装饰。WebView 等原生子控件可能自己处理落在它们上面的拖放。`detach()` 幂等；窗口关闭后 detach 只释放 Target 的原生引用。

### 拖动数据

`system.transfer` 描述拖放携带的序列化内容。`Data` 是有序的 `Item`，每个 item 是同一内容的多种表示（`Representation`，格式是 MIME 名，编码由应用明确约定），不同 item 是不同的值。`Representation.fromBytes` 借用字节，`Representation.lazy(format, provider)` 只声明格式：provider 在 owner 线程上、目标真正请求该格式时运行，每次拖动最多一次，错误也被缓存，必须快速返回且不得等待其他 owner 线程工作，耗时内容应事先准备好。`text`、`html`、`uri_list`、`file_list`、`png`、`markdown` 是常用格式；`TextData`、`UrlData` 和 `fileData(allocator, paths)`（绝对路径转义为 `file://` URL，每个路径一个 item，同时提供 file list 和 URI list；不读也不删文件）构造常见内容，`files(allocator, data)` 只返回本地路径（远端主机和其他 scheme 被忽略），`UriIterator` 跳过注释和空行。`Data.read` 按单一选择对象的约定合并：text 用换行连接、URI/file list 用 CRLF，其余格式取第一个提供它的 item。`preferredFormat`/`Offer.preferred` 按接收方的偏好顺序协商，不请求任何字节。`Snapshot` 用显式 allocator 复制 Data 并持有 provider 缓存，`materialize` 把选定格式复制成不含 provider 的 `Owned`。

`Operations` 是 copy/move 集合，空集表示 copy；`negotiate(source, destination, suggested)` 在两端都允许时采用修饰键建议（Ctrl 为 copy，Shift 为 move），否则 copy 先于 move。

### 拖动源

`system.drag.Source` 从窗口当前的指针手势启动系统拖动：在处理按下或按住按钮的移动时调用 `source.start(allocator, window, data, .{ .operations, .preview, .context, .on_done })`。data 被复制成 Snapshot；原生会话在输入回调返回后才开始（Windows 经辅助窗口消息，GTK 经 `App.post`），所以输入和帧不会在中途被挂起。同时只有一个拖动（`DragActive`），`start` 立即返回的错误不启动任何东西也不调用 on_done。`on_done(context, source, Result)` 在 owner 线程上恰好运行一次，包括取消、原生启动失败、源窗口关闭和 App 停机；`Result.operation` 是目标最终的效果，`canceled` 表示没有放下，`escaped` 区分放弃（Escape、`cancel()`、源窗口关闭、停机）与在无目标处松开，`point` 是结束时的桌面坐标（与 `desktop.cursorPosition` 相同），`err` 报告原生或 provider 失败。只有 `.move` 成功后才移除原件，框架从不删除文件。`preview` 是直通 alpha 的 RGBA8，一个像素一个 DIP，最大 4096，hotspot 以像素计，开始时复制；不给则使用系统默认反馈。Source 从 start 到 on_done 保持地址稳定，lazy provider 的 context 也一样。

Windows 用延迟渲染的 `IDataObject`、`IDropSource` 和 `DoDragDrop`：每种格式以同名注册格式提供原始字节，text 另提供 `CF_UNICODETEXT`，html 提供 `HTML Format`（CF_HTML），png 提供 `PNG`，URI list 提供 `UniformResourceLocatorW`（第一个 URL），file list 提供 `CF_HDROP`；请求流时给出精确长度的 IStream。`IDragSourceHelper` 显示按窗口 DPI 缩放的预览，Shell 写入的私有格式存放在数据对象里。`DoDragDrop` 在系统的模态跟踪循环中运行，与移动、调整大小和菜单循环一样，App 的唤醒在其中照常分发；`cancel()` 让下一次 `QueryContinueDrag` 返回取消，源窗口销毁也取消。GTK 用 `gtk_drag_begin_with_coordinates` 和异步 selection：text 另提供 `UTF8_STRING` 和 `text/plain;charset=utf-8`，file list 提供 `text/uri-list`；`drag-failed` 区分无目标与 Escape，源窗口销毁视为放弃，GTK 的拖动不需要嵌套循环。

### 多格式放置目标

`system.drop.DataTarget` 是多格式的放置目标：`.{ .context, .on_drop, .on_hover, .formats, .operations, .allocator }` 后 `attach(window)`。来源至少提供一个 `formats` 中的格式、且两端有共同的操作时才接受；悬停（`DataHover`：phase、point、`Offer` 和协商出的 operation、`local`）不读取字节，on_hover 仍可拒绝。放下时只请求被接受的格式，`DataDrop.data` 在 on_drop 期间借用目标的存储，`on_drop` 返回是否接受，来源据此得到 operation 或 none。来自本进程的拖动保留全部 item（`local`），其他来源合并成一个 item；Windows/GTK 原生格式按上面的映射还原（CF_HDROP 还原为 file list 和 URI list，CF_HTML 取片段，UTF-16 转 UTF-8），每种表示最多 64 MiB，URI list 中没有本地文件时不算 file list。一个窗口只能有一个放置目标（`Target` 或 `DataTarget`），否则 `AlreadyAttached`。

## 异步文件选择器

Owner 提供四种操作，参数都是 `(options, destination, context, on_result)`：

| 方法 | 原生行为 |
| --- | --- |
| `openFile` | 选择单个已有文件 |
| `openFiles` | 选择多个已有文件，最多 128 条路径 |
| `saveFile` | 系统保存选择器，可创建或替换用户确认的文件 |
| `pickFolder` | 选择目录 |

`system.picker.Options.extensions` 最多 16 项，每项是 `"*"` 或以点开头的扩展名。空切片对打开/目录操作采用 `"*"`，保存采用 `".txt"`；保存不接受 `"*"`。`suggested_name` 默认 `"Untitled"`，最多 256 个 UTF-16 单元。选项在启动返回前复制进原生对象。

```zig
try owner.saveFile(.{
    .extensions = &.{".txt"},
    .suggested_name = "report",
}, &path_buffer, context, completed);
```

同一 Owner 只允许一个 pending 选择器；重复启动返回 `DialogAlreadyPending`。启动成功后不阻塞调用者。原生 completion 只触发它自己持有的内核事件；App 的单次原生等待回调返回主线程后读取 WinRT 结果并调用 `on_result(context, window, result)`，不创建后台线程或嵌套消息循环。每个 pending 选择器占用一个 `App.watchNative` 槽位；等待注册失败时不会启动对话框。

Result 为 `selected: []const u8`、`selected_multiple: []const []const u8`、`cancelled` 或 `failed { err, hresult }`。所有路径字节都写入调用者提供的 destination，无尾零；多选路径连续存放。多选的切片元数据只在回调期间借用，需要长期保留时由应用复制元数据。destination 容量不足返回 `ResultCapacityExceeded`，不截断结果；非文件系统项目返回 `NonFilesystemSelection`。保存操作可能已经创建文件，后续结果缓冲错误不会删除它。

`cancelFileDialog()` 请求取消，最终结果仍通过正常完成回调交付，通常为 `cancelled`；若选择已经完成，取消请求不会撤回该结果。`detach` 或关闭窗口则撤销等待并请求取消，**不再调用业务完成回调**。调用者缓冲和回调 context 至少保留到完成回调，或 Owner detach/窗口 `on_closed`；共享 context 还须覆盖正在执行的其他回调。

原生状态没有 Zig 或 App 指针。WinRT 若迟到释放 completion，它只保留独立事件和引用计数，不访问已关闭的 Owner。`system.picker.resourceCount()` 统计这些适配状态，不统计系统选择器进程或系统内部内存，也不通过阻塞等待强求立即归零。

Linux 使用模态、`transient-for` 窗口的 `GtkFileChooserNative`：在沙箱或设置 `GTK_USE_PORTAL=1` 时走桌面门户，否则显示 GTK 自己的对话框。两者都通过 `response` 信号报告，在 idle 中交付结果，不调用 `gtk_dialog_run`，也不占用 `App.watchNative` 槽位。打开操作把所有扩展名合成一个过滤器（含 `"*"` 时不过滤），保存操作每个扩展名一个过滤器；扩展名按大小写不敏感匹配，不接受 `[` `]`。保存的建议文件名没有列出的扩展名时补上第一个扩展名，并启用覆盖确认。只接受本地路径：没有本地路径的项返回 `NonFilesystemSelection`，不能转为 UTF-8 的路径返回 `InvalidPathEncoding`。`cancelFileDialog()` 隐藏对话框并以 `cancelled` 完成；detach 或窗口关闭销毁对话框且不回调。Linux 的 `system.picker.resourceCount()` 为 0，选择器记录计入 `system.message.resourceCount()`。

使用系统 `Windows.Storage.Pickers` 异步接口和 HWND 初始化。WinRT API 从系统目录的 `combase.dll` 显式加载，每次请求平衡初始化和释放，不依赖单独安装 C++/WinRT 库。[桌面 HWND 初始化规则](https://learn.microsoft.com/en-us/windows/apps/develop/files/using-file-folder-pickers#use-winrt-pickers-with-hwnd-interop)

## 显式后台 Shell 工作

`shell.Worker.init(main_thread_id)` 只能在应用自己创建的后台线程调用，拒绝 UI 线程；Worker 的所有方法和 `deinit()` 都留在该线程。它不持有 App、Window、业务 context 或完成回调，不创建隐藏线程、工作池或消息循环。应用自己通过 `App.post` 交付结果，处理 `Full/Closed` 并在退出时 join。这里只执行无本地 UI 的进程、磁盘和离屏图标操作；Owner 的原生窗口操作仍在主线程。

`try worker.launchExecutable(allocator, .{ .executable = absolute_path, .arguments = argv, .cwd = absolute_directory })` 返回拥有的 `shell.Child`。路径、参数和 cwd 只借用到返回；参数为独立 UTF-8 字符串，支持空参数，拒绝 NUL/非法 UTF-8。最多 128 个参数、单项 16 KiB、参数文本总量 64 KiB；Windows 转义后的命令行另限 32766 个 UTF-16 单元。cwd 可省略以继承当前目录。环境继承当前进程，不隐式更改全局环境。

Windows 要求明确的绝对 `.exe` 路径，直接传给 `CreateProcessW.lpApplicationName`，不搜索 PATH/PATHEXT，不启用 `.bat/.cmd`、文件关联或命令解释器。参数按常规 Windows argv 规则转义；目标程序若使用自己的命令行解析规则，应由宿主遵守其协议。Linux 使用绝对可执行路径及独立 argv，不拼接 shell 命令。启动控制台进程时 Windows 不创建额外控制台窗口，三个标准流不建立宿主管道。

Worker 和 Child 都只有一个所有者，初始化/启动后不可复制。Child 必须在创建它的 worker 上调用 `wait()` 或 `terminateAndWait()`；它们是明确的阻塞操作，关闭/回收一次，后续调用返回保存的 `Term`。`Term.Exited` 保留 Windows 完整 32 位退出码。`terminateAndWait()` 只终止该 Child 所拥有的进程，不遍历名称/PID、不终止进程树。Child 不绑定窗口寿命：窗口关闭或结果投递失败后，宿主仍须回收它，不能在 UI 线程 join 或等待子进程。

`LaunchOptions.cancellation` 借用可跨线程 `request()` 的原子取消标记，仅做提交前检查；请求取消不承诺撤回已经提交的程序启动，也不会自动终止 Child。Worker/Child 的 `last_failure` 在有可靠原生码时保存 Win32/HRESULT；普通系统错误保留 Zig 错误，不编造陈旧的原生码。错误现场数据只在 worker 读取，需要显示时由宿主复制交付。

`try worker.fileIcon(path, .{ .size = 32, .background = 0xffffff }, destination)` 在 Windows 读取系统小/大图标，size 仅允许 16 或 32。结果的 `pixels` 借用调用者 destination，格式为自顶向下 RGBA8，alpha 固定 255，图标原始透明度已经由 `DrawIconEx` 合成到指定 RGB 背景。每次最多 4096 字节输出；不提取缩略图、不解码任意图片、不承诺高分辨率透明图标。容量/取消/原生失败不发布部分像素。HICON、HBITMAP、DC 和 COM 引用都在 worker 内配对释放；不会把原生句柄交给 UI。

图标首次查询在该 worker 初始化 COM，`deinit` 对称释放。查询可能触发系统图标提供者，取消在同步系统调用前后检查，不能中断正在运行的提供者，也没有固定耗时承诺。Linux 的 `fileIcon` 明确返回 `UnsupportedCapability`。

`openUrl`、`openPath`、`reveal`、`trash` 同样是 worker 上的阻塞调用：先检查线程与 Closed，再做提交前取消检查、参数校验，原生调用前再检查一次取消；取消不能撤回已经交给系统的请求。成功只表示系统接受请求，不返回、不拥有也不等待处理程序进程，不保证窗口出现或获得前台。失败时 `last_failure` 记录 Win32、HRESULT、`shell_file_operation`（`SHFileOperationW` 自有返回码，并非 Win32 错误）或 GLib 的 `gio`/`dbus`/`glib` 域 GError 码；纯校验失败保持 null。Windows 首次调用这些方法时与 `fileIcon` 共用该 worker 的 STA COM 初始化，`deinit` 对称释放。

`try worker.openUrl(url, .{ .extra_schemes = &.{"myapp"} })` 只接受绝对 URI：合法 UTF-8、无 NUL、最多 8 KiB；scheme 按 RFC 3986 语法且至少两个字符（单字母视为盘符拒绝）；拒绝 0x21 以下字节、DEL、`` " < > \ ^ ` { | } `` 和不完整的 `%XX`；http/https 必须带非空 `//host`。默认只允许 `https`、`http`、`mailto`，`extra_schemes` 是宿主明确追加的允许表，最多 32 项、不区分大小写；`file` 在 URL 和允许表中一律拒绝，本地路径必须走 `openPath`。非 ASCII 文本原样交给系统，不做 IDN/规范化转换；允许表之外不再判断目标是否可信。Windows 使用 `ShellExecuteExW` 动词 `open`，`SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI`，不请求进程句柄；`ERROR_NO_ASSOCIATION` 映射为 `NoAssociation`。Linux 使用 GIO `g_app_info_launch_default_for_uri`，不经 shell、不拼接 `xdg-open` 命令，不提供 `GAppLaunchContext`（没有启动通知令牌或显示器选择）；GIO 以分离方式启动或经 D-Bus 激活处理程序，无默认处理程序映射为 `NoAssociation`。

`try worker.openPath(absolute_path, .{})` 要求已存在的绝对路径（不跟随最后一级符号链接检查存在），用系统关联打开文件或目录。可执行文件、脚本或快捷方式会按其关联直接运行且不带参数；哪些路径可以传入由宿主决定，本模块不判断内容是否可执行或可信。Windows 把 `/` 规范为 `\` 后交给 `ShellExecuteExW` `open`；Linux 经 `g_filename_to_uri` 后同样调用 `g_app_info_launch_default_for_uri`。

`try worker.reveal(absolute_path, .{ .timeout_ms = 5000 })` 在文件管理器中显示并选中已存在的项。Windows 用 `SHParseDisplayName` 得到 PIDL，`SHOpenFolderAndSelectItems` 后 `ILFree` 释放，`timeout_ms` 不起作用。Linux 在 worker 上为每次调用建立一条私有会话总线连接，同步调用 `org.freedesktop.FileManager1.ShowItems`（URI 数组加空 startup id），返回前关闭连接；超时取值 1..60000 ms，超时为 `RevealTimedOut`。没有会话总线、服务不存在或不可激活时返回 `FileManagerUnavailable`，不回退为打开父目录或启动其他程序。GDBus 使用 GLib 进程级内部工作线程收发消息；本模块不创建线程。

`try worker.trash(absolute_path, .{})` 把一个已存在的项移入回收站，自身绝不回退为永久删除。拒绝文件系统根（`/`、`C:\`、`\\server\share`）。Windows 另拒绝 `*`/`?`（`SHFileOperationW` 会展开通配符），只接受本地固定盘（UNC 和非 `DRIVE_FIXED` 返回 `TrashUnsupported`），使用双 NUL 路径与 `FO_DELETE`、`FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT`，非零返回为 `TrashFailed`，`fAnyOperationsAborted` 为 `TrashAborted`。固定盘检查只是保守前置条件：回收站被禁用、超过容量等情况下系统如何处理仍由 Windows 回收站策略决定，本模块无法从该接口区分。Linux 使用 `g_file_trash`：`G_IO_ERROR_NOT_SUPPORTED`（例如该文件系统没有可用的 trash 目录）映射为独立的 `TrashUnsupported`，不存在为 `FileNotFound`，权限为 `AccessDenied`。

S02 当前仍为部分实现：Windows/Linux 已提供 `launchExecutable`、`openUrl`、`openPath`、`reveal`、`trash`，Windows 另有 16/32 像素 `fileIcon`；完整图标（Linux/高分辨率/透明）、安装应用发现及按安装身份启动尚未实现，`installed_applications`、`launch_application` 仍为 false。`launchExecutable` 是明确二进制程序启动，不代替安装应用枚举。

## 桌面环境

`system.desktop` 在 App owner 线程提供显示器、偏好（color scheme、accent、高对比度、减少动态/透明、文字缩放）、电源和网络快照，写入调用者存储且不分配；`Watch` 是调用者持有的变化订阅，每个 Watch 拥有自己的原生订阅，突发合并为每种类最多一次回调，stop 与 App 关闭撤销，停止后的 Watch 不再收到回调，没有轮询计时器。网络 `online` 只表示本地连接。Windows 用从不显示的顶层窗口接收广播，Linux 用 GDK/GtkSettings/GIO 信号。平台差异、启发式和已验证范围见[桌面环境](desktop-environment.md)。

## 应用目录

`paths.Paths.init("Notes")` 按名称解析常用目录，`get(allocator, name)` 返回调用者释放的路径：home、app_data（`$XDG_CONFIG_HOME`，默认 `~/.config`；Windows `%AppData%`）、user_data（app_data/应用名）、cache（`$XDG_CACHE_HOME`，默认 `~/.cache`；Windows `%LocalAppData%`，再接应用名）、logs（user_data/logs）、resources（可执行文件所在目录，解析符号链接后）、temp、exe，以及 desktop/documents/downloads/music/pictures/videos（Linux 读取 `user-dirs.dirs` 并展开 `$HOME`，否则为 home 下的同名目录）。user_data、cache 与 logs 首次 `get` 时创建；`resolve` 只计算不创建。`set(name, path)` 借用覆盖路径，原样返回且不创建。相对的 XDG 目录按规范忽略；缺少 home 时返回 `PathUnavailable`。应用名不得含路径分隔符或保留字符。

## 菜单标准角色

`menu_roles.Role` 列出常用命令（撤销、重做、剪切、复制、粘贴、全选、重新载入、缩放、全屏、最小化、关闭、新建、打开、保存、另存为、退出等）和标准子菜单（文件、编辑、显示、窗口、格式、应用菜单）。`defaults(role, context)` 给出按语言的标签与快捷键：内置英文、简体中文、繁体中文、日文，`resolve(locale, overrides)` 先取应用覆盖、再取内置语言、最后英文；Windows 上重做是 Ctrl+Y、退出叫“退出/Exit”且无快捷键，Linux 重做是 Ctrl+Shift+Z、退出是 Ctrl+Q；`documents = true` 时文件菜单带文档命令，关闭项称“关闭”而非“关闭窗口”。

`Builder.init(items, labels, context)` 把角色写成普通 `Item`，标签写入调用者提供的存储，子菜单角色带出默认条目，同一角色重复出现时（如文件与窗口菜单中的关闭）分配下一个出现序号，只有第一个带快捷键。角色项 ID 位于 `menu_roles.id_base` 之上，`Role.fromId` 还原角色；应用自己的 ID 保持在其下。切换语言时用新 locale 重新构建并再次 `setMenu`。`menu_role_actions.perform(app, window, id)` 执行窗口与应用类角色的默认动作（退出走 `requestQuit`，关闭走用户关闭请求，最小化、缩放、全屏切换），编辑、视图与文档类角色返回 `unhandled`，交给当前内容处理。快捷键键名新增 `plus`（主键盘区的 =/+ 键）与 `minus`。

## 信号退出

`signals.QuitOnSignals.start(app)` 让 SIGINT 与 SIGTERM 变成一次 `requestQuit`：信号处理函数只向管道写一个字节，由默认 GLib 主上下文在主线程读取后调用，关闭处理器照常运行并可取消；第二个信号在处理函数里直接以 128 + 信号值退出进程，即使主线程繁忙或上一次退出被取消。进程启动时已被忽略的信号（如后台作业的 SIGINT）保持忽略。每个进程同时只有一个实例，`stop()` 恢复原处理函数；App 关闭时自动停止。Windows 没有这两个信号，返回 `UnsupportedCapability`。

## 提示音、指针位置与已安装应用

`desktop.beep(app)` 播放系统提示音（Windows `MessageBeep`，GTK `gdk_display_beep`）。`desktop.cursorPosition(app)` 返回与 `Monitor` 相同坐标系的指针位置；Wayland 不公开全局指针位置，返回 `UnsupportedCapability`。

`shell.Worker.installedApps(allocator)` 在后台 worker 上列出启动器可见的应用，按名称（忽略大小写）再按路径排序，结果由 `InstalledApps.deinit` 一次释放。Windows 枚举 Shell 的 Applications 文件夹（开始菜单“所有应用”，打包应用与桌面应用都在内），id 是 AppUserModelID（或已知文件夹下的路径），path 是 `shell:AppsFolder\<id>`；Linux 列出菜单会显示的桌面条目（排除 NoDisplay/Hidden 和不属于当前桌面的条目），id 是桌面文件 ID，path 是 `.desktop` 文件。`launchApp(path)` 启动其中一项：Windows 交给 `ShellExecuteEx`（也接受任意程序路径），Linux 用 `GDesktopAppInfo` 启动；worker 线程上没有 GTK 启动上下文，因此没有启动通知。

## 最近文档、Jump List 与重启

`recent.RecentDocuments.load(allocator, file, capacity)` 读取应用自己的最近文档列表（JSON，新的在前），文件缺失或损坏时从空列表开始；`add` 把路径移到最前、去重并截到容量，`remove`、`clear` 修改列表，每次修改都先写同目录临时文件再改名替换。它只管理应用自己的 Open Recent 列表（菜单角色 `open_recent`），不登记到系统。`recent.addToSystem(allocator, path, app_name)` 把绝对路径登记到系统：Windows 调用 `SHAddToRecentDocs`，进入用户的最近项目和本应用 Jump List 的 Recent 类别（仅限应用已注册处理程序的文件类型）；Linux 用 GLib 同步编辑 GTK 使用的 `recently-used.xbel`，写入 MIME 类型和应用名，文件选择器和文件管理器的“最近”会显示它。两者都会阻塞，不适合放在逐帧路径上。

`jump_list.setTasks(allocator, tasks, .{ .app_id, .recent })`（仅 Windows）用 `ICustomDestinationList` 一次替换整个 Jump List：每个任务是一个 shell link，有标题、提示、程序（默认本程序）、参数、工作目录和图标，`recent = true` 另加 Recent 类别。参数按常规 argv 规则逐项加引号，`argumentLine` 给出与 shell link 相同的字符串。所有输入先校验（标题必填、最多 32 个任务、文本不超过 259 字节且不含控制字符、程序须为绝对路径）再调用系统；任何一步失败都会放弃新列表，原列表保持不变。没有任务也不要 Recent 时删除整个列表。Windows 在应用退出后仍保留列表，通常启动时设置一次。需要作用于正在运行的应用时，把本应用的 URL scheme 作为参数，再由单实例转发给 primary。Linux 没有对应的任务菜单，返回 `UnsupportedCapability`。

`relaunch.Relaunch.request(app)` 在事件循环运行期间、owner 线程上调用 `requestQuit`：关闭处理器照常运行，取消退出时重启也一并取消。Windows 会先把前台权限交出去，让新进程的窗口能到最前。`App.run` 返回、App 与单实例锁等资源释放之后，`finish(allocator, options)` 再启动新进程（默认本程序并沿用当前参数，也可以改程序、参数和工作目录），不等待它结束，然后返回 true；没有被接受的请求时返回 false。

## 文件监视

`system.watch.Watcher` 是 S03 的粗模式文件监视：与 `shell.Worker` 相同，只在宿主创建的后台线程初始化和调用（`interrupt()` 除外，可跨线程唤醒），不创建线程、不轮询，所有缓冲和预算（root、目录 watch、pending、路径字节、原生缓冲）在 `init` 显式分配。`addRoot` 返回即 ready；`wait(events, path_storage, timeout_ms)` 按 debounce 与最大延迟交付合并后的 `changed`（应重新列出的目录）、`overflow`（必须重扫整个 root）和 `root_removed`，调用者容量不足时顺延而不丢弃。Linux 使用 inotify/eventfd/poll，Windows 使用 overlapped `ReadDirectoryChangesW`。它不读取文件 metadata、不匹配 rename，详细模式尚未实现。合同、预算与验证范围见 [文件监视](file-watch.md)；Windows 路径目前只验证交叉编译。

## 密钥存储

`system.secrets` 把访问令牌、API 密钥等小块机密交给系统凭据存储：Windows 是 Credential Manager，Linux 是会话总线上的 Secret Service（GNOME Keyring、KWallet、KeePassXC 等，经 libsecret）。系统替当前用户加密，不同于应用自己写的文件。每个机密以“服务名 + key”标识：服务名把一个应用的机密分成一组，通常是应用的反向域名标识；同一用户的其他程序给出相同服务名和 key 时读到同一个机密。Windows 写入 generic credential，target 为 `service/key`，用户名为 key，`CRED_PERSIST_ENTERPRISE`；Linux 写入 `org.freedesktop.Secret.Generic` schema 的条目，`service`/`account` 属性为服务名和 key，标签为 `service/key`。按这种约定保存机密的其他程序可以互读。

`set(service, key, value)` 存入或替换，`get(service, key, destination)` 写入调用者缓冲并返回切片，`delete(service, key)` 删除（不存在也算成功）。服务名与 key 为 1–256 字节、不含 NUL 的 UTF-8，机密最多 `max_secret_bytes`（2560 字节，即 Credential Manager 的上限，两个平台行为一致），可以为空或含任意字节。错误：没有该机密为 `SecretNotFound`；目标缓冲不够为 `SecretTooLarge`；会话里没有可用存储为 `CredentialStoreUnavailable`；存储拒绝或失败为 `CredentialStoreFailed`，`secrets.lastFailure()` 给出本线程最近一次的 Win32 错误码或 GError 码。

三个函数都会阻塞（存储可能要求用户解锁），只能在宿主创建的 worker 上调用，App 运行时不要在主线程调用。模块不创建线程、不分配。`secrets.Request` 把一次操作带到 worker：主线程 `Request.init(app, .get, service, key, "", context, on_done)` 校验并复制输入；请求保持稳定地址，worker 调用 `request.run()` 完成阻塞调用后经 `App.post` 把 `on_done` 交回主线程，恰好一次；投递失败（`Full`/`Closed`）时 `run` 返回该错误、不调用 `on_done`，结果留在请求里，由调用者重试 `post()` 或丢弃。`on_done` 里用 `err()` 和 `value()` 读取结果，`wipe()` 擦除请求持有的机密明文。

Linux 首次使用时才 `dlopen("libsecret-1.so.0")`（需要 0.19 起的二进制接口），所以 libsecret 只是运行时可选依赖。没有该库、没有会话总线，或总线上没有 Secret Service（D-Bus 报告 `ServiceUnknown`、`NameHasNoOwner`、`NoServer`）时，每个操作都返回 `CredentialStoreUnavailable`，不会假装成功；已存在但被锁定、用户拒绝等其他总线错误为 `CredentialStoreFailed`。libsecret 的同步调用自带 main context，可在任意 worker 上运行。

## 浮出窗口

`system.Flyout` 是锚定在某个矩形旁边的无边框弹出窗口：托盘应用的面板、按钮展开的列表或悬停卡片。它没有边框、任务栏按钮或自己的背景，内容（UI Context、WebView 等，照常 attach 到 `flyout.window`）绘制全部区域。`var flyout: system.Flyout = .{}` 后 `try flyout.open(app, options)` 创建、放置并（除非 `hidden`）显示；Flyout 从 open 到窗口 `on_closed` 期间保持稳定地址，`Options.on_closed` 由它转发。

锚点 `Anchor` 有三种：`.window = .{ .owner, .rect }` 是 owner 客户区内的 DIP 矩形（打开它的元素的边框，或空矩形表示一个点），owner 拥有该浮出窗口，它保持在 owner 之上、随 owner 移动或缩放重新放置（核心把 owner 的 `resize`/`window_position` 转告 `PopupHandler.owner_moved`），并随 owner 关闭；`.screen` 是原生桌面坐标中的矩形（与 `desktop.Monitor` 相同约定：Windows 物理像素，X11 GDK 逻辑坐标）；`.tray` 是通知区图标，系统报告图标位置时放在图标旁，否则放在主显示器工作区正中。后两种没有 owner，浮在其他应用窗口之上。

`placement` 是 12 种放置之一：`bottom_start`、`bottom`、`bottom_end`、`top_*`、`right_*`、`left_*`，即位于锚点哪一侧，以及沿该侧与锚点起始边、中心还是末尾对齐；`gap` 是与锚点的 DIP 距离。目标显示器取与锚点重叠最多的工作区，没有重叠时取离锚点中心最近的显示器。每个轴上，放不下时若翻到锚点另一侧或另一端能放下就翻转，然后沿越界的边滑回工作区，仍放不下则缩小到工作区；纯函数 `flyout.placeBeside` 公开并有单元测试。`setAnchor` 换到同类锚点（窗口锚点须同一 owner）后重新放置，`setSize(width, height)` 按内容测得的尺寸调整大小并重新放置，`place()` 按当前状态重放。Wayland 不报告窗口位置，此时只设置尺寸，由合成器放置。

`focusable = true` 的浮出窗口显示时取得键盘；其他窗口取得键盘（Windows：激活离开且新激活窗口不是它自己或它拥有的窗口）或在 Linux 上用户按在它外面时被“驳回”，按用户关闭处理（`requestCloseFrom(.user)`），`on_close` 可以拒绝。托盘浮出窗口在 Windows 上点自己的图标不算驳回，图标的点击交给应用切换它。非 focusable 的浮出窗口从不取得键盘：显示、聚焦和指针按下都不改变当前活动窗口，直到被关闭，适合 tooltip、悬停卡片和输入框建议。两种浮出窗口在内容未消费的 Escape（无修饰键）上都按用户关闭处理。`shadow` 使用系统弹出阴影（Windows `CS_DROPSHADOW`，Windows 11 另按菜单样式圆角和描边；Linux 不画阴影）。

托盘点击弹出浮出窗口：在 `Tray` 的 `on_action` 收到 `.activate` 时调用 `flyout.toggle(app, .{ .anchor = .{ .tray = tray }, .placement = .bottom, .gap = 4, .width = 280, .height = 230, .focusable = true })`，已打开时关闭、否则打开。`Tray.iconRect()` 返回 Shell 报告的图标矩形（Windows `Shell_NotifyIconGetRect`）；Linux status notifier 宿主只报告点击坐标，作为空矩形锚点使用，没有报告时浮出窗口居中。

底层是核心的 `WindowOptions.popup: ?PopupRole`（`focusable`、`topmost`、`shadow`、`handler`），要求 `.borderless` 且不能是模态窗口（`InvalidPopup`）。Windows 上它是 `WS_POPUP` + `WS_EX_TOOLWINDOW` 窗口（不进任务栏和 Alt+Tab），非 focusable 时加 `WS_EX_NOACTIVATE`、`WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE` 并以 `SW_SHOWNOACTIVATE` 显示；拥有可见 focusable 弹出窗口的窗口被点击激活时返回 `MA_ACTIVATEANDEAT`，那次点击只驳回弹出窗口，与菜单一致；驳回在 `WM_ACTIVATE` 之后用投递消息决定，不在激活处理中回调。Linux X11 上它是 `GTK_WINDOW_POPUP`（override-redirect，精确放在计算出的位置），focusable 时显示期间 `gdk_seat_grab` 抓取整个 seat 并 `gtk_grab_add`，外部按下（含本应用其他窗口和其他应用）或抓取被打断时驳回；没有 X11 时退回 utility 类型的顶层窗口，失去键盘时驳回。两平台都设置不进任务栏/分页器。

## Now Playing 与媒体键

`system.NowPlaying` 把应用正在播放的内容放到系统显示媒体的地方：Windows 是音量浮出面板与锁屏上的媒体控件（SystemMediaTransportControls），Linux 是 MPRIS 客户端（GNOME、KDE 的媒体控件与锁屏、playerctl）。显示期间，键盘与耳机的媒体键以及这些控件把命令交给应用：

```zig
var now = system.NowPlaying.init(allocator, &state, onCommand);
try now.start(app);
try now.set(.{ .title = "Spring", .artist = "Vivaldi", .album = "The Four Seasons", .artwork = cover_png,
    .duration_ns = 200 * std.time.ns_per_s, .commands = .{ .play = true, .pause = true, .next = true, .seek = true } });
// onCommand(context, command, position_ns) 在主线程：播放、暂停或跳转，再用 setPlayback 告诉系统。
```

- 所有调用和 `on_command` 都在 App owner 线程。NowPlaying 由调用者持有，`start` 后地址不变，`stop` 或 App 关闭时撤销；一个进程同时只有一个（否则 `AlreadyActive`）。
- `Info`：标题、艺术家、专辑（各最多 1024 字节 UTF-8）、封面（PNG 或 JPEG）、`duration_ns`（0 为未知，如直播，不显示进度）、`position_ns`、`rate`（0 即 1）、`state`（默认 `playing`）、`commands`（全不设为播放、暂停、停止）。字符串和封面都被复制。系统在 `playing` 时按 rate 自己推进位置，应用只在跳转时用 `setPlayback(state, position_ns)` 更新；`clear()` 让系统控件不再显示应用、媒体键交给其他应用；`current()` 返回带当前位置的信息。
- 命令：`play`、`pause`、`stop`、`next`、`previous`、`seek`。播放/暂停键在 `playing` 时为 `pause`，否则为 `play`；未提供的命令被忽略。`seek` 的位置是目标位置（限制在曲目内），其他命令给出命令到达时的播放位置，便于 `setPlayback(.paused, position_ns)` 停在原处。
- `control(Player)` 让媒体键直接驱动播放器（`Player.of(&audio_player)` 适配 `ziggurat_audio` 的 Player 或任何有 `play`/`pause`/`stop`/`isPlaying`/`seek`/`position`/`duration` 的值）：播放、暂停、停止与跳转作用于播放器，显示的状态、位置和时长取自播放器，并额外提供播放、暂停、停止以及（时长已知时）跳转；`next`/`previous` 仍交给 `on_command` 换曲，其他命令在播放器处理后也照常交给 `on_command`。应用自己操作播放器或播放结束后调用 `sync()`。
- Windows：控件属于一个从不显示的顶层窗口（经 `ISystemMediaTransportControlsInterop`），设置播放状态、各按钮可用性、音乐元数据、缩略图、时间线与速率；控件在自己的线程调用敏捷委托，委托只向该窗口投递消息，命令在主线程交付。窗口、控件与委托首次使用时创建并保留到进程结束。
- Linux：会话总线上的 MPRIS 播放器（`/org/mpris/MediaPlayer2`），只在显示期间持有总线名 `org.mpris.MediaPlayer2.<程序名>.instance<pid>`，清除后离开桌面控件。`Identity` 是 GLib 应用名，`DesktopEntry` 是程序名（与 `identity.setProcessIdentity` 一致）。曲目变化时换 trackid；位置跳变超过半秒发 `Seeked`；`Seek` 与 `SetPosition`（只接受当前曲目、曲目内的位置）作为 `seek`；封面写到 `$XDG_RUNTIME_DIR/<程序名>/` 下的文件并以 `file://` 给出，封面变化或清除时删除；`OpenUri` 返回 NotSupported。没有会话总线时不显示，也不报错。

`zig build smoke-now-playing`（需要 `dbus-run-session` 与 X11）用另一条总线连接作为 MPRIS 客户端，验证总线名、元数据与封面文件、可用命令、播放/暂停键、未提供的命令被忽略、`SetPosition` 与 `Seek`、`OpenUri` 拒绝、清除后离开总线并删除封面。`zig build smoke-now-playing-commands` 在两个平台经各自后端的主线程路径（Windows 为窗口消息）交付命令，验证播放/暂停键按状态、未提供的命令、跳转位置与清除后不再交付；Windows 上的系统控件显示与真实媒体键没有自动验证。

## 图标

`system.Icon.fromPng(app, png)` 把 PNG 字节（最大 1024×1024，先读头部尺寸再解码）变成平台图标：Windows 是 `CreateIconFromResourceEx` 得到的 HICON，Linux 是 GdkPixbuf。`icon.handle()` 就是 `TrayOptions.icon`/`TrayItemOptions.icon` 借用的原生图标，所以托盘可以直接用 PNG。`system.icon.setWindowIcon(window, &icon)` 设置窗口标题栏和任务栏图标，null 恢复应用图标；Windows 的 `WM_SETICON` 不复制图标，Icon 必须在所有显示它的窗口换掉图标或关闭后才 `deinit`，GTK 自己持有引用。菜单项用的图标见[菜单项图标](#菜单项图标)。

## 外观跟随

`system.theme.Follower` 决定应用的明暗外观：`.system` 跟随桌面，`.light`/`.dark` 强制。`start(app, .{ .source, .on_change })` 读取桌面偏好、应用外观并订阅偏好变化；`setSource` 随时切换；`isDark()` 是生效的外观，`preferences()` 是最近一次读到的桌面偏好（accent、高对比度、减少动态/透明、文字缩放）。外观或偏好变化后调用 `on_change`，应用在这里切换自己绘制内容的主题（例如 `ui.Context.setTheme(.dark())`）。系统自己绘制的部分由 Follower 处理：Windows 上 `track(window)` 的窗口标题栏随外观切换（`DWMWA_USE_IMMERSIVE_DARK_MODE`），弹出菜单经 uxtheme 的 preferred app mode（Windows 10 1903 起）跟随；Linux 设置 `gtk-application-prefer-dark-theme`，强制浅色时名字以 `-dark` 结尾的主题换成去掉后缀的同名主题，跟随桌面时恢复 GTK 自己的设置。属性只在值变化时写入，所以桌面 Watch 收到的通知都是真实变化。`setWindowButtons(window, source)` 让某个窗口的边框与标题栏按钮不管应用外观、按深色或浅色背景绘制（例如浅色应用里标题区是深色的页面），`.system` 恢复跟随应用；菜单和应用内容仍是应用的外观，Linux 上 GTK 的按钮始终跟随应用。单独的 `theme.setWindowDark(window, dark)` 只在 Windows 可用。

## 无窗口常驻

`AppOptions.on_all_windows_closed` 设置后，App 在没有窗口时继续运行，直到 `requestQuit`/`quit`，适合常驻通知区的应用：最后一个窗口关闭时在 dispatch 安全点调用它而不是退出，`run` 在没有窗口时启动也不返回。它可以创建新窗口或退出。没有窗口时事件循环保持空闲，不会反复唤醒。

## 剪贴板清空与位图

`board.clear()` 清空系统剪贴板，不论 owner 是谁；本 Board 仍在的 offer 随之结束。Windows 在一次 `OpenClipboard` 中 `EmptyClipboard`，被占用时与 write 一样返回 `ClipboardBusy`；GTK 先清除本 Board 的内容，再把 CLIPBOARD selection 的 owner 设为空，X11 允许任何客户端这样做。

Windows 上大多数程序把图片作为位图（`CF_DIB`，系统也会从其他位图格式合成）放进剪贴板：没有 `PNG` 流时，读取 `png` 把未压缩的 24/32 位位图转换成 8 位 RGBA PNG（`system.bitmap.dibToPng`，纯 Zig，用 stored deflate 块），formats 也报告 png 可用。只有 BITMAPINFOHEADER 之后更新的头部才使用 alpha 字节；位图尺寸按不可信输入检查，输出最多 64 MiB。

## 异步打开 URL

`system.OpenUrl` 在 owner 线程上打开一个 URL 而不阻塞它：`start(app, url, options, context, on_done)` 校验并复制 URL，为这一次请求启动一个线程，用 `shell.Worker.openUrl` 交给系统，然后在 owner 线程调用 `on_done`，结果在 `request.result`。线程属于请求本身，没有线程池。请求从 start 到 on_done 或 App 停机结束期间地址稳定；停机等待该线程结束，之后不再调用 on_done。`options.extra_schemes` 借用同样长的时间。

## 已验证范围

`zig build smoke-drag` 用真实输入（X11 上 XTest，Windows 上 SetCursorPos/SendInput）在两个窗口间拖动：同进程的多 item、多格式（含一个 lazy 表示）拖动完整到达 DataTarget，copy 与 Shift 的 move 协商一致且 provider 每次拖动只渲染一次；Escape、`cancel()`、在无目标处松开、目标拒绝格式都只结束一次且结果正确；files/text 的 `Target` 收到同一拖动的文本；另一个进程拖入的文本、自定义格式和文件作为一个 item 到达。

`zig build smoke-system-details` 在隐藏窗口下检查：位图编码成的 PNG 由系统解码为图标并设为窗口图标（Windows 另用于托盘项）；同一 PNG 做成菜单项图标后，下拉菜单里的命令显示图标、菜单栏自身的项不显示，`setItemIcon` 替换和去掉图标，GTK 重建的勾选项保留图标，Windows 位图是 16 DIP 按窗口 DPI 的 32 位 DIB，Linux 托盘菜单项的 `icon-data` 就是 PNG 字节；强制深色/浅色时 Windows 标题栏属性与 GTK 的 prefer-dark 设置随之变化，切回跟随后与桌面偏好一致；写入文本后 `clear` 使剪贴板为空；Windows 上手工放入 `CF_DIB` 后读到可解码的 PNG；Linux 上用未关联的 scheme 异步打开 URL，在 owner 线程收到失败结果；关闭唯一窗口后 App 继续运行，由 `on_all_windows_closed` 之后的任务退出。`smoke-system-menus` 另检查单选项的原生标记与同组互斥。

`zig build smoke-system-session` 在隐藏窗口的事件循环中经 `Relaunch` 退出，再真实启动自身。被启动的子进程在 Linux 上把私有 `XDG_DATA_HOME` 下的文件两次登记到最近文档，读回 `recently-used.xbel`，确认只有一条记录且带应用名。在 Windows 上，子进程登记最近文档，设置含两个任务和 Recent 类别的 Jump List 后再删除；再按 Jump List 的参数串用 `CreateProcessW` 启动自身，确认空参数、空格、引号、尾部反斜杠、UNC 前缀和非 ASCII 参数都原样往返。这些检查不打开或点击任务栏菜单，也不检查 shell 的显示效果。

`zig build smoke-system-extras` 在隐藏窗口下播放提示音、读取指针位置、在后台 worker 上列出已安装应用并确认启动不存在的条目失败；Linux 另向本进程发送 SIGTERM，确认经 `requestQuit` 退出事件循环并停止信号处理，Windows 确认信号退出返回 `UnsupportedCapability`。

`zig build smoke-system` 实际创建菜单和 Shell 托盘项，覆盖 12 轮 owner/窗口生存期、菜单状态、原生命令、同 HWND 更换 Owner 后的旧消息、任务栏重建恢复，以及回调内关闭的清理。

`zig build smoke-system-events` 覆盖真实快捷键注册/冲突/注销、12 轮更换/关闭与旧消息、ID 耗尽、真实静默通知提交和清理。快捷键触发和通知点击由原生消息注入，不代表已经验证物理按键、人工点击或用户可见送达。关闭后重新注册同一系统快捷键成功，USER/GDI 句柄计数在预热后保持不变。

`zig build smoke-picker` 实际调用打开、保存、多选和目录四种原生异步操作，再取消并等待一次主线程完成；另覆盖唯一窗口启动后立即销毁，禁止晚到 Zig 回调。本机测试结束时适配状态计数为零。

`zig build smoke-picker-result` 用原生 ABI 替身驱动生产 Picker，覆盖单选、多选、UTF-16 surrogate、恰好容量、容量不足且不部分写入、无效文本/路径/数量、HRESULT、取消及 detach/restart 等 12 类结果与寿命场景，另检查操作代数耗尽。它也验证回调释放自身存储、直接 detach 期间原生关闭不会提前释放上下文；不打开系统对话框。

`zig build smoke-system-menus`（Windows）在隐藏窗口上跑真实的 `TrackPopupMenuEx`：计时器在系统菜单循环里投递方向键和回车完成选择，另验证跟踪中取消、跟踪前取消、跟踪中 detach 不回调、空菜单/零 ID/非有限坐标被拒绝。菜单栏快捷键通过设置线程键盘状态并发送键消息验证：Ctrl+S、单独 F5 触发，自动重复、缺修饰键、禁用命令和禁用 submenu 下的 Alt+Z 不触发，重复/非法快捷键被拒绝。独立托盘实际向 Shell 添加两个图标，验证激活/右键事件、旧 ID 事件被忽略、原地更新、锚定菜单选择、任务栏重建后重新添加、显式移除后 Shell 中已无该项、重新 show 使用新 ID，以及留下的图标在 App 停止时被移除。消息框真实创建 MessageDialog，再取消并等待一次主线程完成；另验证启动后立即关闭唯一窗口时消息框和菜单都不回调。

`zig build smoke-system-menus`（Linux，Xvfb）在已映射窗口上打开真实 GTK 菜单，通过 GTK 激活接口完成根项、未打开过的 submenu 项和禁用祖先下的项（报告 null），验证禁用项不可激活、取消、重复请求被拒绝和 detach 不回调；消息框验证按钮、关闭（报告取消按钮）、`cancelMessage`（dismissed）和打开时销毁窗口。Linux 版另覆盖菜单栏：附加后窗口根控件变为纵向盒、命令激活、Ctrl+S 快捷键、Content 先消费 Ctrl+O 时菜单不触发、禁用项与禁用 submenu 下的命令及其快捷键不触发、`setItemState` 加上/去掉勾选并在 GTK 自行切换后还原、替换快照、`clearMenu` 和 detach 后绘制区回到窗口原位，以及菜单栏存在时打开弹出菜单与关闭窗口。按键由 GDK 事件注入。选择由原生激活接口或消息注入完成，不代表物理按键、人工点击或视觉质量已验收。

`zig build smoke-system-desktop`（Linux，需要会话总线和 X11：`dbus-run-session -- xvfb-run -a zig build smoke-system-desktop`）在同一私有总线上用测试替身充当 status notifier watcher 和通知服务器。托盘：导出并登记、读取 ToolTip/IconName/IconPixmap 属性（验证调用后释放的 pixbuf 已被复制为 ARGB）、`Activate`/`ContextMenu` 事件、原地更新、超长提示被拒绝；独立托盘：`guid` 写入 `Id`、更换身份被拒绝、在宿主报告的点打开菜单并选择、重复请求被拒绝、移除。通知：urgency/`suppress-sound`/`transient` 提示、激活后撤回、已显示的通知被替换时撤回、总线连接前被替换的通知不发送、服务器关闭只清理、旧 ID 的激活被忽略。全局快捷键用 XTest 注入真实 X 按键：触发、按住重复只报告一次、进程内重复和另一 X 客户端已抓取的组合被拒绝（`last_error` 非零）、注销后组合可再次注册。选择器：GTK 对话框中实际选择文件、保存到目录加文件名、选择子目录，取消、容量不足、启动后 detach 不回调；多选由原生结果替身完成（GTK 自带对话框没有可脚本化的多选）。最后在菜单栏、托盘、快捷键、通知和选择器都存在时关闭窗口。这些替身不证明某个具体桌面面板或通知守护进程的显示效果。

**Windows 尚未自动操作真实系统 GUI 完成文件/目录选择或保存确认，系统成功结果到返回路径的完整链路仍需原生集成验证；Linux 未验证门户路径。** 这些检查不评价对话框、菜单或图标的视觉质量，也不证明其他系统运行支持。

`zig build smoke-secrets` 在 worker 上经 `Request` 对真实存储依次执行删除、读取不存在、写入 2560 字节、读回比较、替换为含 NUL/非 ASCII 的值、写入空值、删除和重复删除，结果都在主线程核对；服务名和 key 含非 ASCII 字符，只读写测试自己的服务名，不读取用户已有凭据。Windows 必须有 Credential Manager；Linux 默认在没有 Secret Service 时要求每个操作都报告 `CredentialStoreUnavailable`，`--require-store` 则要求真实往返。本地已在 `dbus-run-session` 下分别验证 GNOME Keyring 解锁后的完整往返、总线上无 Secret Service 时的明确错误，以及存储弹出解锁提示但无法显示时的 `CredentialStoreFailed`。

`zig build smoke-flyout` 显示一个 owner 窗口并验证：非 focusable 浮出窗口出现在与 `placeBeside` 计算一致的位置、拥有者是 owner、显示后 owner 仍是活动窗口；owner 移动后浮出窗口跟随；focusable 浮出窗口在 Linux 上由 XTest 注入真实 Escape 后按用户关闭，在 owner 区域注入真实点击后被驳回，`on_close` 拒绝时保持打开；Windows 上激活 owner 驳回它（会话没有前台权限时跳过键盘部分并打印说明）；无 owner 的屏幕矩形浮出窗口放在矩形右侧。Linux 已在 Xvfb 1x、GDK_SCALE=2 以及有无 openbox 时运行通过；Windows 本次只在 Linux 上交叉编译。托盘锚点的居中与放置、跟随、驳回、Escape 和 owner 关闭另由测试后端单元测试覆盖。这些检查不评价阴影、圆角等视觉效果。

`zig build smoke-shell` 使用测试程序自身作为受控 helper，验证 Windows/Linux 的 Unicode、空格、空参数、引号、反斜杠、换行和字面 shell 字符、cwd、预取消、跨线程拒绝、缺失程序、活进程终止和重复回收；12 轮自有子进程后句柄/文件描述符计数不增长，首个失败路径预热后再验证 12 轮失败计数持平。Windows 另验证完整退出码、16/32 像素图标只读查询及 GDI/内核句柄稳定。进程全局计数可以在首次系统调用后增长，并非模块自有资源归零承诺。

同一 smoke 还验证 open/reveal/trash 的跨线程、Closed、预取消、相对路径、NUL、非法 UTF-8、超长 URL、拒绝的 scheme（`file`、`javascript`、`ftp`、`ms-settings`、盘符、允许表中的 `file`）、缺失路径、非法超时、文件系统根及 Windows 通配符；这些请求都在交给处理程序之前失败。Linux 另用一个私有未注册 scheme 走到真实 GIO，断言 `NoAssociation` 和 `gio` 域失败码；把 HOME/XDG_DATA_HOME 指向测试目录，真实 `g_file_trash` 12 个 Unicode 文件，确认原路径消失、`Trash/files` 内容和 `Trash/info/*.trashinfo` 存在，首个调用后描述符计数持平；若环境不支持 trash，只接受 `TrashUnsupported`。Windows 对测试目录中的临时文件真实调用 12 次 `trash`（进入当前用户回收站），非固定盘时只接受 `TrashUnsupported`。

在 `dbus-run-session` 等提供 `DBUS_SESSION_BUS_ADDRESS` 的环境中，若总线上没有 FileManager1，smoke 先断言 `reveal` 返回 `FileManagerUnavailable`，再由测试自身在该总线上以不排队方式占有 `org.freedesktop.FileManager1`（已有真实文件管理器时跳过，不替换它），验证 13 次 `ShowItems` 恰好收到一个可还原为原路径的 `file://` URI、首轮后描述符持平，以及 200 ms 超时返回 `RevealTimedOut`。没有会话总线时只做参数检查。

**未自动验证：**真实浏览器/邮件客户端/关联程序打开 URL 或文件、Windows `reveal` 的真实资源管理器显示、真实 Linux 文件管理器的 ShowItems 行为、Windows 非固定盘与回收站被禁用或超容量时的系统处理；Windows 路径目前只在 Linux 上交叉编译，尚未在本次修改后于 Windows 运行。测试不改变默认应用关联，不评价图标或文件管理器视觉质量。

`zig build smoke-clipboard` 在一个 App 内用真实系统剪贴板写入 text/html/png/custom/files 五种格式，再异步查询格式并逐一读回比较（Unicode 与 surrogate 文本、CF_HTML/`text/html` 片段、PNG 流、路径列表；Windows custom 只比较前缀，因为 GlobalSize 可含填充），覆盖容量不足报告所需字节、缺失格式、重复启动拒绝、取消后无回调、lazy offer 只在读取时渲染且每次只能 set 一次、eager 写入与 revoke 各释放 provider 一次、revoke 后读取为空，以及 App 停机时 pending 读取无回调且 live offer 被释放；另做 12 轮 Board 创建/写入/读取/销毁。Linux 最后检查只剩最后一次 eager offer 的原生记录。测试不模拟另一进程占用剪贴板，Windows 有界重试与 `WM_RENDERALLFORMATS` 退出渲染尚未自动验证。

`zig build smoke-drop` 12 轮验证放置目标的真实原生注册（Windows OLE 窗口属性、GTK target 列表标记）、重复 attach 拒绝、detach 幂等与重新 attach、窗口销毁时注册在原生销毁前撤销且之后不再回调；悬停接受/拒绝与 payload 复制/容量报告通过 adapter 入口驱动。真实拖放链路（OLE `DragEnter/Drop`、GTK `drag-motion/drag-data-received`）由 `smoke-drag` 的注入输入覆盖。
