# 桌面环境

`system.desktop` 提供显示器、系统偏好、电源和网络的快照，以及由原生通知驱动的变化订阅。所有调用都在 App owner 线程（`app.assertOwner()`）。快照写入调用者存储，不分配；没有轮询计时器、后台线程或嵌套事件循环。`system.desktop.capabilities`（也挂在 `system.capabilities.desktop`）按平台报告支持状态。文件监视不在本模块范围内。

单元测试使用测试 backend，不初始化 GTK 或原生显示；此时所有快照和 `Watch.start` 返回 `UnsupportedCapability`。非 Windows/Linux/macOS 目标同样返回该错误。

## 快照

| 调用 | 结果 | 原生来源 |
| --- | --- | --- |
| `monitors(app, destination) !usize` | `Monitor { bounds, work_area, scale, primary, refresh_hz }` | Windows `EnumDisplayMonitors`/`GetMonitorInfoW`/`GetDpiForMonitor`/`EnumDisplaySettingsW`；Linux `GdkDisplay` 显示器；macOS `NSScreen` |
| `preferences(app) !Preferences` | `color_scheme`、`accent`、`high_contrast`、`reduce_motion`、`reduce_transparency`、`text_scale` | Windows HKCU 注册表与 `SystemParametersInfoW`；Linux `GtkSettings`；macOS 应用的 `effectiveAppearance`、`NSColor.controlAccentColor` 与 `NSWorkspace` 辅助功能显示选项 |
| `power(app) !Power` | `source: ac/battery/unknown`、`battery_percent: ?u8`、`saver: ?bool` | Windows `GetSystemPowerStatus`；Linux `/sys/class/power_supply` 与 `GPowerProfileMonitor`；macOS IOKit 电源（`IOPSCopyPowerSourcesInfo`）与低电量模式 |
| `network(app) !Network` | `state: online/offline/unknown`、`metered: ?bool` | Windows `GetNetworkConnectivityHint`；Linux `GNetworkMonitor`；macOS Network.framework `nw_path_monitor` |

### 显示器

坐标与核心 `ScreenPoint` 相同：Windows 为物理像素，X11 为 GDK 逻辑坐标，macOS 为以主显示器左上角为原点、y 向下的点（与窗口 bounds 相同）。macOS 的 `scale` 是 `backingScaleFactor`，`refresh_hz` 取 `maximumFramesPerSecond`（macOS 12 起），`primary` 是 `NSScreen.screens` 的第一项（菜单栏所在显示器）。`scale` 在 Windows 为有效 DPI/96（`shcore.dll` 缺失时退回系统 DPI），在 Linux 为 GDK 整数缩放因子。`refresh_hz` 为当前模式刷新率取整，系统未报告（Windows 0/1、GDK 0）时为 null。

结果先写入内部 `max_monitors`（32）项栈缓冲；destination 短于实际数量返回 `CapacityExceeded`，**不写入任何项**；长度为 `max_monitors` 的 destination 总是足够，超过 32 个原生显示器返回 `TooManyMonitors`。Linux 只支持 X11 显示，Wayland 返回 `UnsupportedCapability`。

### 偏好

Windows：`AppsUseLightTheme` 决定 light/dark，缺失为 unknown；`EnableTransparency == 0` 表示 `reduce_transparency`，缺失为 null；accent 优先读 `HKCU\Software\Microsoft\Windows\DWM\AccentColor`（ABGR 转 0xRRGGBB），缺失时用 `DwmGetColorizationColor`；`SPI_GETHIGHCONTRAST` 的 `HCF_HIGHCONTRASTON`；`SPI_GETCLIENTAREAANIMATION` 关闭即 `reduce_motion`；`HKCU\Software\Microsoft\Accessibility\TextScaleFactor` / 100（100–500 之外忽略）。

Linux 使用启发式：`gtk-application-prefer-dark-theme` 为真，或主题名（不区分大小写）含 `dark`/`inverse`，判为 dark；其他非空主题名为 light，无主题名为 unknown。主题名含 `contrast` 判为高对比度。`reduce_motion = !gtk-enable-animations`，`text_scale = gtk-xft-dpi / (96 × 1024)`，未设置时为 1。accent 和 `reduce_transparency` 恒为 null。**不读取 XDG portal 的 color-scheme**：那需要在 UI 线程同步 D-Bus 调用；依赖 portal 而不同步 GtkSettings 的桌面可能报告 light。

macOS：`color_scheme` 是应用 `effectiveAppearance` 最接近 Aqua 还是 Dark Aqua，因此应用用 `theme.apply`/`Follower` 强制外观时报告被强制的值（Follower 跟随桌面时先恢复系统外观再读）。accent 是按应用外观解析的 `controlAccentColor`（sRGB），`high_contrast`、`reduce_motion`、`reduce_transparency` 来自 `NSWorkspace.accessibilityDisplayShouldIncreaseContrast/ShouldReduceMotion/ShouldReduceTransparency`。没有系统级文字缩放，`text_scale` 恒为 1。

### 电源

Windows：`ACLineStatus` 0/1 映射 battery/ac，其余 unknown；无系统电池（`BatteryFlag & 128`）或 255 时百分比为 null；`saver` 取 `SystemStatusFlag` 的节电位。

Linux：同步读取 `/sys/class/power_supply`，最多 16 个条目、每个只读几个短文件（`type`、`online`、`scope`、`capacity`），忽略 `scope=Device` 的外设电池。任一 Mains/USB online 为 ac，否则存在系统电池为 battery，否则 unknown（无条目的台式机和容器即 unknown）。这是内核内存文件的有界读取，但仍是 UI 线程上的同步系统调用。`saver` 在运行时可解析 `g_power_profile_monitor_dup_default`（GLib ≥ 2.70）时读取 `power-saver-enabled`，否则为 null；该监视器是进程级单例，首次使用创建后不释放。没有 power-profiles 服务或服务尚未应答时它报告 false，因此 false 不能证明节电模式确实关闭。

macOS：`IOPSGetProvidingPowerSourceType` 为 Battery Power 时 battery，其他已知来源为 ac；百分比取内置电池的当前容量/最大容量；`saver` 是低电量模式（macOS 12 起，更早为 null）。

### 网络

`online` 只表示本地网络连接存在，**不保证目标服务器可达**，不做 HTTP 或 DNS 探测。

Windows：从 System32 动态加载 `iphlpapi.dll` 的 `GetNetworkConnectivityHint`（Windows 10 2004+）；缺失或失败时为 unknown/null。level None 为 offline，LocalAccess/InternetAccess/ConstrainedInternetAccess 为 online，其余 unknown。roaming/超出流量上限或 cost Fixed/Variable 为 metered，Unrestricted 为非 metered，Unknown 为 null。

Linux：`g_network_monitor_get_network_available` 决定 online/offline。netlink 实现（及其基类）不知道计费状态，此时 `metered` 为 null；其他实现（NetworkManager、portal）报告 `network-metered`。首次调用 `g_network_monitor_get_default` 会初始化 GIO 扩展点，某些实现在初始化时连接系统总线，这是一次性的显式成本，本模块未规避。

macOS：进程级的一个 `nw_path_monitor`，首次快照或网络订阅时在自己的串行队列上启动，之后不释放。路径为 satisfied 即 online，否则 offline；expensive 或 constrained 为 metered。监视器异步报告首个路径（通常几毫秒内），首次快照在主线程最多等待 1 秒，仍未报告时为 unknown/null。

## 变化订阅

```zig
var watch = system.desktop.Watch.init(&state, State.desktopChanged);
try watch.start(app, .{ .monitors = true, .preferences = true, .power = true, .network = true });
// on_change(context, change)：change 是变化种类集合，宿主重新查询快照。
watch.stop();
```

`Watch` 由调用者持有。start 之后不可移动；Watch 与 context 保持有效，直到 `stop()` 返回或 App 停止它。每个 Watch 拥有自己的原生订阅：start 建立、stop 或 App 关闭撤销；同一 Watch 可在 stop 后再次 start。空选择返回 `EmptySelection`，运行中再次 start 返回 `AlreadyStarted`，stopping/stopped App 返回 `Closed`。失败的 start 不注册、不留下原生状态。

start 通过 `App.registerStop` 注册一个 `StopParticipant`；App 关闭的 stop 批次撤销仍在运行的 Watch。`stop()` 幂等，可在 `on_change` 内调用，并通过 `cancelStop` 交还停止责任。若 App 已在停止批次中（例如另一个参与者的 stop 回调调用了它），原生订阅立即撤销，但 Watch 存储须保留到 App 关闭完成。

`Change` 与 `Kinds` 同为 `{ monitors, preferences, power, network }` 布尔集合，只包含 start 时选择的种类。一次原生突发（同一轮里的多条通知）合并成一次回调，每种类最多出现一次。回调在 owner 线程经 `App.beginCallback` 交付；App stopping 后不再交付。回调返回后实现不再访问 Watch，因此回调可以 stop 并释放它。停止的 Watch 永不收到回调。

### Windows

每个 Watch 创建一个从不显示的顶层窗口（进程级窗口类 `ZigguratDesktopWatch`，注册后不注销；Zig 窗口过程经 `GWLP_USERDATA` 找到 Watch）。消息专用窗口收不到广播，因此不用 `HWND_MESSAGE`。

| 消息 | 种类 |
| --- | --- |
| `WM_DISPLAYCHANGE`、`WM_DPICHANGED`、`WM_SETTINGCHANGE(SPI_SETWORKAREA)` | monitors |
| 其他 `WM_SETTINGCHANGE`（含 `ImmersiveColorSet`）、`WM_THEMECHANGED`、`WM_DWMCOLORIZATIONCOLORCHANGED`、`WM_SYSCOLORCHANGE` | preferences |
| `WM_POWERBROADCAST` 的 `PBT_APMPOWERSTATUSCHANGE`/`PBT_POWERSETTINGCHANGE`（`RegisterPowerSettingNotification(GUID_POWER_SAVING_STATUS)`） | power |
| `NotifyNetworkConnectivityHintChange` 回调转发的注册消息 | network |

`WM_SETTINGCHANGE` 不解析区域字符串，其他设置变化都按 preferences 报告。合并方式：通知只累计位，首次累计时向自身 post 一条注册的 flush 消息；flush 交付累计位并清零。网络回调在系统线程运行，只 `PostMessageW` 到隐藏窗口，其上下文是 HWND 值而非 Zig 指针；不请求初始通知。stop 顺序：`CancelMibChangeNotify2`（等待正在运行的回调完成）、注销电源通知、清除 `GWLP_USERDATA`、`DestroyWindow`。队列中残留的消息到达已销毁窗口时被忽略。缺少网络通知 API 时 network 订阅静默不生效，快照为 unknown。隐藏窗口是否收到仅改变缩放而不改变分辨率的显示器 DPI 变化，取决于系统广播，未验证。

### Linux

`src/system/desktop_linux.c` 为每个 Watch 分配一个 GLib 引用计数原生状态，连接：GdkDisplay `monitor-added/monitor-removed`、GdkScreen `monitors-changed/size-changed`；GtkSettings `notify::gtk-application-prefer-dark-theme`、`gtk-theme-name`、`gtk-enable-animations`、`gtk-xft-dpi`；`GPowerProfileMonitor` `notify::power-saver-enabled`（运行时存在时）；`GNetworkMonitor` `network-changed`、`notify::network-metered`、`notify::connectivity`。每次突发只建一个 `G_PRIORITY_DEFAULT_IDLE` idle 源，它持有一份引用。stop 同步清除 owner、断开所有 handler、移除待处理 idle，再释放引用；正在派发的 idle 自己的引用保证状态在回调期间存活。

Linux 不监视 AC/电池或电量变化（没有 udev 订阅），`capabilities.watch_power_source` 为 false；power 订阅只报告节电标志变化。X11 只改变工作区（例如面板移动）而不改变显示器几何时，GDK 不一定发出信号。

### macOS

`src/system/macos_services.m` 为每个 Watch 建一个观察者对象，按所选种类订阅：`NSApplicationDidChangeScreenParametersNotification`（monitors）；应用 `effectiveAppearance` 的 KVO、`NSSystemColorsDidChangeNotification`、`NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`（preferences）；`NSProcessInfoPowerStateDidChangeNotification` 与 `IOPSNotificationCreateRunLoopSource` 加在主 run loop 上的电源源（power，含 AC/电池与电量变化）；共享路径监视器在首个路径之后的更新（network，从监视器队列转到主队列）。一次突发只向主队列派发一个 block，block 持有观察者；stop 同步清除 owner、移除所有观察与 run loop 源，之后到达的 block 不交付。`theme.apply` 只在外观真正改变时设置 `NSApp.appearance`，以免 KVO 通知循环。

## 资源

`desktop.resourceCount()` 统计本模块仍存活的原生 Watch 状态：Windows 隐藏窗口，Linux 引用计数状态，macOS 观察者对象。它不统计进程级窗口类、注册消息、常驻系统 DLL 与 GIO 单例。

## 已验证范围

`zig build smoke-desktop` 在 Xvfb 下（含 `GDK_SCALE=2`）实际验证：至少一个显示器、尺寸/缩放合理、`CapacityExceeded` 不写入；偏好、电源、网络快照可查询；同一 Watch 12 轮 start/stop 后资源计数和 App stop 参与者回到基线；真实 `g_object_set` 修改 GtkSettings 的一次突发（5 条 notify）恰好一次 preferences 回调，第二次突发再一次；回调内 stop 后同步再触发不交付；App 关闭时两个仍运行的 Watch 被停止，其待处理突发不交付，资源归零。

Windows 路径已交叉编译（`x86_64-windows-gnu`），smoke 用 `SendMessageW` 向隐藏窗口注入 `WM_SETTINGCHANGE`、`WM_THEMECHANGED`、`WM_SYSCOLORCHANGE`、`WM_DISPLAYCHANGE` 及未选择的电源广播，期望一次 `{preferences, monitors}` 回调，并检查 USER 对象计数。**本次实现尚未在真实 Windows 上运行该检查。**

`zig build smoke-macos-services` 在 macOS 上验证：至少一个主显示器位于原点、缩放与工作区合理；偏好（含 accent 与减少透明度）、电源来源与低电量模式、网络状态与指针位置可查询；`theme.apply` 强制深色再浅色时 preferences Watch 各收到回调且读回对应外观，回调内 stop 后资源归零。 注入消息不代表系统真实广播；真实主题、显示器、电源和网络变化，Wayland，GPowerProfileMonitor 与 NetworkManager 后端，以及物理电池均未自动验证。
