# 系统工具

按需导入 `ziggurat_system`。当前原生菜单、托盘、文本剪贴板、异步文件选择器、全局快捷键和通知区通知仅实现 Windows；`system.capabilities` 分别报告支持状态。Linux 等目标的这些窗口扩展返回 `UnsupportedCapability`。独立的无 UI `shell.Worker` 已支持 Windows/Linux 显式程序启动，以及 Windows 有界文件图标，能力见 `system.capabilities.shell`。

## 窗口 owner

`Owner.init(context, on_action)` 返回值对象，再用 `try owner.attach(window)` 挂载。附加后的 Owner 不可移动或复制；它与业务 context 保持稳定地址直到 `on_closed`。所有调用和业务回调都在进程主线程。

每个窗口只有一个 `WindowService`，Owner 在其中组合菜单、托盘、选择器、快捷键和通知，不占用 `Content`。窗口原生销毁时先清除 service 入口，再撤销选择器等待、注销快捷键、移除通知和托盘、释放菜单和图标。`try owner.detach()` 可提前移除服务；它不会 detach UI/WebView 内容。重复 detach 无副作用。

原生消息中的命令 ID 来自窗口的 `reserveNativeIds`，在该 HWND 生存期内不复用，包括换 Owner、替换菜单和失败配置。耗尽返回 `IdExhausted`，不会把旧消息投递给新动作。框架不保留全局业务回调表。

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

`setItemState(id, enabled, checked)` 更新命令项；submenu 状态变化用新的 `setMenu` 快照。`clearMenu()` 移除菜单栏。当前没有自建快捷键表或同步 `TrackPopupMenu` 弹出接口，也不自行嵌套运行消息循环。

## 托盘

`setTray(.{ .icon = borrowed_hicon, .tooltip = "工具" })` 创建或替换一个托盘项。icon 为 null 时复制系统默认应用图标；传入图标只在调用期间借用，Owner 持有独立 `CopyIcon` 结果。tooltip 复制到固定存储，最多 127 个 UTF-16 单元。`clearTray()` 删除图标并释放本地图标句柄。

使用 `NOTIFYICON_VERSION_4`。激活产生 `Action.tray_activate`；右键或键盘菜单请求产生 `Action.tray_context: ScreenPoint`，坐标是屏幕像素。应用决定如何显示自己的菜单或窗口。Owner 接收 `TaskbarCreated` 后重建自己的托盘项；失败通过窗口诊断 sink 报告。附加期间保留窗口消息 `WM_APP + 0x421`。[系统通知区协议](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw)

## 全局快捷键

`registerHotkey(id, .{ .key = .f24, .modifiers = .{ .control = true, .shift = true } })` 在 Owner 的 HWND 注册系统级快捷键。业务 ID 非零，同一 Owner 内唯一，最多同时 32 项。Key 是字母、数字、F1–F24 及常用导航键的命名枚举，修饰键为 control/alt/shift/super；默认禁止按住自动重复，可显式设置 `repeat = true`。Windows 保留 F12，因此注册它返回 `UnsupportedKey`。

原生注册冲突返回 `HotkeyRegistrationFailed`，原始系统码保留在 `owner.last_error`；失败不占活动槽位。收到有效消息产生 `Action.hotkey: u64`。`unregisterHotkey(id)` 移除一项，未知 ID 返回 `HotkeyNotFound`；`clearHotkeys()` 移除全部。detach/窗口关闭也主动注销。每次注册使用新的窗口原生 ID，已经移除或上一个 Owner 的排队消息不会调用新动作。Windows 要求快捷键 ID 不超过 `0xBFFF`，本窗口的 ID 区间耗尽时返回 `IdExhausted`，不会绕回复用。原生注册规则见 [RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)。

## 通知区通知

`showNotification(id, .{ .title = "完成", .body = "导出完成" })` 向 Windows Shell 提交一条通知区通知。业务 ID 非零、body 非空；title/body 分别最多 63/255 个 UTF-16 单元，超长或非法文本返回错误，保留原通知。kind 为 info/warning/err，默认 silent 和 real_time 为 true，系统不能立即显示时丢弃。每个 Owner 同时保留一条通知，使用独立复制图标，不需要配置持久托盘项。成功替换采用新的原生 ID；通知文本在调用中交给系统复制，不保留调用者切片。

点击产生 `Action.notification_activated: u64`，在调用业务回调前删除对应 Shell 项并释放图标。hide/timeout 只清理，不调用业务动作。`clearNotification()`、detach 和窗口关闭均回收通知；任务栏重建后不重播过时消息。晚到通知事件只匹配其原始 ID。

这是 [NIF_INFO 通知区接口](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw)，不提供现代 Toast 的 action buttons、通知历史或送达保证。调用成功只证明 Shell 接受提交；系统设置、专注模式、用户操作等决定实际展示。

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

## 文件监视

`system.watch.Watcher` 是 S03 的粗模式文件监视：与 `shell.Worker` 相同，只在宿主创建的后台线程初始化和调用（`interrupt()` 除外，可跨线程唤醒），不创建线程、不轮询，所有缓冲和预算（root、目录 watch、pending、路径字节、原生缓冲）在 `init` 显式分配。`addRoot` 返回即 ready；`wait(events, path_storage, timeout_ms)` 按 debounce 与最大延迟交付合并后的 `changed`（应重新列出的目录）、`overflow`（必须重扫整个 root）和 `root_removed`，调用者容量不足时顺延而不丢弃。Linux 使用 inotify/eventfd/poll，Windows 使用 overlapped `ReadDirectoryChangesW`。它不读取文件 metadata、不匹配 rename，详细模式尚未实现。合同、预算与验证范围见 [文件监视](file-watch.md)；Windows 路径目前只验证交叉编译。

## 已验证范围

`zig build smoke-system` 实际创建菜单和 Shell 托盘项，覆盖 12 轮 owner/窗口生存期、菜单状态、原生命令、同 HWND 更换 Owner 后的旧消息、任务栏重建恢复，以及回调内关闭的清理。

`zig build smoke-system-events` 覆盖真实快捷键注册/冲突/注销、12 轮更换/关闭与旧消息、ID 耗尽、真实静默通知提交和清理。快捷键触发和通知点击由原生消息注入，不代表已经验证物理按键、人工点击或用户可见送达。关闭后重新注册同一系统快捷键成功，USER/GDI 句柄计数在预热后保持不变。

`zig build smoke-picker` 实际调用打开、保存、多选和目录四种原生异步操作，再取消并等待一次主线程完成；另覆盖唯一窗口启动后立即销毁，禁止晚到 Zig 回调。本机测试结束时适配状态计数为零。

`zig build smoke-picker-result` 用原生 ABI 替身驱动生产 Picker，覆盖单选、多选、UTF-16 surrogate、恰好容量、容量不足且不部分写入、无效文本/路径/数量、HRESULT、取消及 detach/restart 等 12 类结果与寿命场景，另检查操作代数耗尽。它也验证回调释放自身存储、直接 detach 期间原生关闭不会提前释放上下文；不打开系统对话框。

**尚未自动操作真实系统 GUI 完成文件/目录选择或保存确认，系统成功结果到返回路径的完整链路仍需原生集成验证。** 这些检查不评价对话框、菜单或图标的视觉质量，也不证明其他系统运行支持。

`zig build smoke-shell` 使用测试程序自身作为受控 helper，验证 Windows/Linux 的 Unicode、空格、空参数、引号、反斜杠、换行和字面 shell 字符、cwd、预取消、跨线程拒绝、缺失程序、活进程终止和重复回收；12 轮自有子进程后句柄/文件描述符计数不增长，首个失败路径预热后再验证 12 轮失败计数持平。Windows 另验证完整退出码、16/32 像素图标只读查询及 GDI/内核句柄稳定。进程全局计数可以在首次系统调用后增长，并非模块自有资源归零承诺。

同一 smoke 还验证 open/reveal/trash 的跨线程、Closed、预取消、相对路径、NUL、非法 UTF-8、超长 URL、拒绝的 scheme（`file`、`javascript`、`ftp`、`ms-settings`、盘符、允许表中的 `file`）、缺失路径、非法超时、文件系统根及 Windows 通配符；这些请求都在交给处理程序之前失败。Linux 另用一个私有未注册 scheme 走到真实 GIO，断言 `NoAssociation` 和 `gio` 域失败码；把 HOME/XDG_DATA_HOME 指向测试目录，真实 `g_file_trash` 12 个 Unicode 文件，确认原路径消失、`Trash/files` 内容和 `Trash/info/*.trashinfo` 存在，首个调用后描述符计数持平；若环境不支持 trash，只接受 `TrashUnsupported`。Windows 对测试目录中的临时文件真实调用 12 次 `trash`（进入当前用户回收站），非固定盘时只接受 `TrashUnsupported`。

在 `dbus-run-session` 等提供 `DBUS_SESSION_BUS_ADDRESS` 的环境中，若总线上没有 FileManager1，smoke 先断言 `reveal` 返回 `FileManagerUnavailable`，再由测试自身在该总线上以不排队方式占有 `org.freedesktop.FileManager1`（已有真实文件管理器时跳过，不替换它），验证 13 次 `ShowItems` 恰好收到一个可还原为原路径的 `file://` URI、首轮后描述符持平，以及 200 ms 超时返回 `RevealTimedOut`。没有会话总线时只做参数检查。

**未自动验证：**真实浏览器/邮件客户端/关联程序打开 URL 或文件、Windows `reveal` 的真实资源管理器显示、真实 Linux 文件管理器的 ShowItems 行为、Windows 非固定盘与回收站被禁用或超容量时的系统处理；Windows 路径目前只在 Linux 上交叉编译，尚未在本次修改后于 Windows 运行。测试不改变默认应用关联，不评价图标或文件管理器视觉质量。
