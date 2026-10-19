# 系统工具

按需导入 `ziggurat_system`。原生菜单栏、菜单快捷键、上下文菜单、异步消息框、窗口托盘、独立托盘、异步文件选择器、全局快捷键和通知实现 Windows 和 Linux；文本剪贴板目前仅 Windows。`system.capabilities` 分别报告编译目标的支持状态，未实现的窗口扩展返回 `UnsupportedCapability`。Linux 的托盘与通知走会话总线，全局快捷键只在 X11 上可用，运行时缺少对应服务或显示协议时按下文各节明确报告。独立的无 UI `shell.Worker` 已支持 Windows/Linux 显式程序启动，以及 Windows 有界文件图标，能力见 `system.capabilities.shell`。

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

`setItemState(id, enabled, checked)` 更新命令项；submenu 状态变化用新的 `setMenu` 快照。`clearMenu()` 移除菜单栏。禁用的 submenu 使其下所有命令（含快捷键）失效。

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

## 文本剪贴板

`system.clipboard.writeText(window, utf8)` 和 `readText(window, destination)` 复用原生文本适配器。读取返回写入调用者缓冲的字节数；容量不足、文本无效或剪贴板被占用时返回错误，不重试或等待。写入只在显式复制操作中分配系统内存，成功后所有权转交系统。当前仅有 UTF-8 文本 API，没有图片、拖放或延迟渲染所有权接口。

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

S02 当前仍为部分实现：打开 URL/文件关联、文件定位、回收站、安装应用发现及按安装身份启动尚未实现，对应 `shell.capabilities` 均为 false。`launchExecutable` 是明确二进制程序启动，不代替安装应用枚举或 Shell 关联能力。

## 已验证范围

`zig build smoke-system` 实际创建菜单和 Shell 托盘项，覆盖 12 轮 owner/窗口生存期、菜单状态、原生命令、同 HWND 更换 Owner 后的旧消息、任务栏重建恢复，以及回调内关闭的清理。

`zig build smoke-system-events` 覆盖真实快捷键注册/冲突/注销、12 轮更换/关闭与旧消息、ID 耗尽、真实静默通知提交和清理。快捷键触发和通知点击由原生消息注入，不代表已经验证物理按键、人工点击或用户可见送达。关闭后重新注册同一系统快捷键成功，USER/GDI 句柄计数在预热后保持不变。

`zig build smoke-picker` 实际调用打开、保存、多选和目录四种原生异步操作，再取消并等待一次主线程完成；另覆盖唯一窗口启动后立即销毁，禁止晚到 Zig 回调。本机测试结束时适配状态计数为零。

`zig build smoke-picker-result` 用原生 ABI 替身驱动生产 Picker，覆盖单选、多选、UTF-16 surrogate、恰好容量、容量不足且不部分写入、无效文本/路径/数量、HRESULT、取消及 detach/restart 等 12 类结果与寿命场景，另检查操作代数耗尽。它也验证回调释放自身存储、直接 detach 期间原生关闭不会提前释放上下文；不打开系统对话框。

`zig build smoke-system-menus`（Windows）在隐藏窗口上跑真实的 `TrackPopupMenuEx`：计时器在系统菜单循环里投递方向键和回车完成选择，另验证跟踪中取消、跟踪前取消、跟踪中 detach 不回调、空菜单/零 ID/非有限坐标被拒绝。菜单栏快捷键通过设置线程键盘状态并发送键消息验证：Ctrl+S、单独 F5 触发，自动重复、缺修饰键、禁用命令和禁用 submenu 下的 Alt+Z 不触发，重复/非法快捷键被拒绝。独立托盘实际向 Shell 添加两个图标，验证激活/右键事件、旧 ID 事件被忽略、原地更新、锚定菜单选择、任务栏重建后重新添加、显式移除后 Shell 中已无该项、重新 show 使用新 ID，以及留下的图标在 App 停止时被移除。消息框真实创建 MessageDialog，再取消并等待一次主线程完成；另验证启动后立即关闭唯一窗口时消息框和菜单都不回调。

`zig build smoke-system-menus`（Linux，Xvfb）在已映射窗口上打开真实 GTK 菜单，通过 GTK 激活接口完成根项、未打开过的 submenu 项和禁用祖先下的项（报告 null），验证禁用项不可激活、取消、重复请求被拒绝和 detach 不回调；消息框验证按钮、关闭（报告取消按钮）、`cancelMessage`（dismissed）和打开时销毁窗口。Linux 版另覆盖菜单栏：附加后窗口根控件变为纵向盒、命令激活、Ctrl+S 快捷键、Content 先消费 Ctrl+O 时菜单不触发、禁用项与禁用 submenu 下的命令及其快捷键不触发、`setItemState` 加上/去掉勾选并在 GTK 自行切换后还原、替换快照、`clearMenu` 和 detach 后绘制区回到窗口原位，以及菜单栏存在时打开弹出菜单与关闭窗口。按键由 GDK 事件注入。选择由原生激活接口或消息注入完成，不代表物理按键、人工点击或视觉质量已验收。

`zig build smoke-system-desktop`（Linux，需要会话总线和 X11：`dbus-run-session -- xvfb-run -a zig build smoke-system-desktop`）在同一私有总线上用测试替身充当 status notifier watcher 和通知服务器。托盘：导出并登记、读取 ToolTip/IconName/IconPixmap 属性（验证调用后释放的 pixbuf 已被复制为 ARGB）、`Activate`/`ContextMenu` 事件、原地更新、超长提示被拒绝；独立托盘：`guid` 写入 `Id`、更换身份被拒绝、在宿主报告的点打开菜单并选择、重复请求被拒绝、移除。通知：urgency/`suppress-sound`/`transient` 提示、激活后撤回、已显示的通知被替换时撤回、总线连接前被替换的通知不发送、服务器关闭只清理、旧 ID 的激活被忽略。全局快捷键用 XTest 注入真实 X 按键：触发、按住重复只报告一次、进程内重复和另一 X 客户端已抓取的组合被拒绝（`last_error` 非零）、注销后组合可再次注册。选择器：GTK 对话框中实际选择文件、保存到目录加文件名、选择子目录，取消、容量不足、启动后 detach 不回调；多选由原生结果替身完成（GTK 自带对话框没有可脚本化的多选）。最后在菜单栏、托盘、快捷键、通知和选择器都存在时关闭窗口。这些替身不证明某个具体桌面面板或通知守护进程的显示效果。

**Windows 尚未自动操作真实系统 GUI 完成文件/目录选择或保存确认，系统成功结果到返回路径的完整链路仍需原生集成验证；Linux 未验证门户路径。** 这些检查不评价对话框、菜单或图标的视觉质量，也不证明其他系统运行支持。

`zig build smoke-shell` 使用测试程序自身作为受控 helper，验证 Windows/Linux 的 Unicode、空格、空参数、引号、反斜杠、换行和字面 shell 字符、cwd、预取消、跨线程拒绝、缺失程序、活进程终止和重复回收；12 轮自有子进程后句柄/文件描述符计数不增长，首个失败路径预热后再验证 12 轮失败计数持平。Windows 另验证完整退出码、16/32 像素图标只读查询及 GDI/内核句柄稳定。进程全局计数可以在首次系统调用后增长，并非模块自有资源归零承诺。测试不打开浏览器、用户文件或回收站，不改变默认应用关联，不评价图标视觉质量。
