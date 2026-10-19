# 单实例与系统集成

`ziggurat_system` 中的 `identity`、`instance`、`integration`、`power` 与 `taskbar` 提供应用身份、单实例与参数转发、按用户注册的登录启动/深链/文件关联、阻止休眠，以及任务栏或 dock 状态。它们不持有 App、不创建线程、不轮询；能力分别见 `system.capabilities.identity/instance/integration/power/taskbar`。macOS 不在当前范围内，所有入口在其他目标返回 `UnsupportedCapability`。

## 应用身份

一个应用 ID 贯穿整套能力：单实例锁、Linux `<id>.desktop`、Windows AppUserModelID、launcher entry 与注册的处理程序都使用它。`identity.validate(id)` 只接受 1–64 字节的 ASCII 字母、数字、`.`、`_`、`-`，不允许首尾点或空的点分段，因此可直接作为文件名、管道名和 desktop ID。

`identity.setProcessIdentity(id)` 必须在主线程、`App.init` 和任何窗口之前调用：Windows 设置显式 AppUserModelID，使任务栏按该 ID 分组；Linux 设置 GLib 程序名，GTK 启动时据此得到 X11 `WM_CLASS` 和 Wayland app ID。GTK 启动后再调用不会改变已有窗口。

## 系统目录

`identity.directory(kind, destination)` 把绝对路径写入调用者缓冲，不创建目录，不追加分隔符。`applicationDirectory(kind, id, destination)` 只用于 `config/data/cache/state`，在其后拼上应用 ID。

| kind | Windows | Linux |
| --- | --- | --- |
| home | Profile | `$HOME` |
| config / data | Roaming AppData | `XDG_CONFIG_HOME` / `XDG_DATA_HOME`，默认 `~/.config`、`~/.local/share` |
| cache / state | Local AppData | `XDG_CACHE_HOME` / `XDG_STATE_HOME`，默认 `~/.cache`、`~/.local/state` |
| temp | `GetTempPathW` | `TMPDIR`，默认 `/tmp` |
| desktop、documents、downloads、pictures、music、videos | Known Folder（不验证存在） | `user-dirs.dirs` |

Linux 只接受绝对的环境值，相对值按规范忽略。用户目录未配置或指向 `$HOME` 本身（xdg-user-dirs 的禁用写法）时返回 `DirectoryUnavailable`，不猜测位置；唯一例外是规范给出默认值的桌面目录 `~/Desktop`。`LinuxEnvironment` 允许测试或打包工具显式提供全部输入。缓冲不足返回 `ResultCapacityExceeded`，不截断。

## 单实例与参数转发

```zig
var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
const cwd = try std.process.getCwd(&cwd_buffer);
var primary = (try system.instance.claimOrForward(.{ .id = "org.example.Notes" }, .{
    .cwd = cwd,
    .arguments = args[1..],
}, 8)) orelse return; // 已转发给正在运行的实例
defer primary.deinit();
```

`instance.claim(options)` 获取当前用户的锁，返回 `.primary` 或 `.secondary`。它在创建窗口之前调用，不触碰 App。`claimOrForward` 组合常见流程：成为 primary，或把一次消息转发给 primary 后返回 null。正在退出的 primary 可能在 secondary 看到锁之后拒绝连接，此时 `forward` 返回 `PrimaryUnavailable`，`claimOrForward` 以逐次增长的短暂停顿重新 claim，最多 `attempts`（1–16）次。它会阻塞调用者，只用于进程启动阶段。

Primary 不可复制。`receive(storage, arguments)` 由应用自己创建的一个 worker 调用，阻塞到一次对端交换结束或 `requestStop()`；`requestStop` 可在任何线程调用，之后 `receive` 持续返回 `.stopped`。join worker 后在原线程调用 `deinit`。`storage` 至少 `receive_storage_bytes`，`arguments` 至少 `max_arguments` 项，否则直接返回 `ResultCapacityExceeded`；同时只允许一个 `receive`。

结果为三种：

- `.message`：`cwd`、`arguments` 与 OS 报告的 `sender_process`。切片借用 storage，直到下一次 `receive`。应用复制所需数据并 `App.post` 到主线程，再自己决定激活含义，例如 `window.perform(.restore)`、`.focus` 或打开转发的文件。`post` 返回 `Full/Closed` 时数据仍归 worker。
- `.rejected`：`malformed`、`too_large`、`timeout`、`foreign_user` 或 `disconnected`。对端被拒，listener 继续可用。
- `.stopped`。

消息只有在完整读入并校验后才确认。帧为固定头（魔数、负载长度、字符串个数、保留零）加逐项 u32 长度和字节：最多 128 个参数，单项 16 KiB，cwd 与参数合计 64 KiB 负载。字节原样转发，不要求 UTF-8，但拒绝 NUL；长度越界、未消费完、多余字节、超出数量都按 `malformed`/`too_large` 拒绝。每次连接后的交换受 `timeout_ms`（1–60000，默认 2000）约束，停滞的对端得到 `timeout` 而不会占住 listener。`Secondary.forward` 只发送一次，并在同一时限内等待确认；primary 明确拒绝时返回 `Rejected`。确认之后的转发是至少一次语义：secondary 若在 primary 已接受后超出时限仍未读到确认（Windows 断开管道时会丢弃未读字节），它报告失败，`claimOrForward` 可能重试，因此应用应容忍重复的激活请求。

### 平台实现

- **Linux**：锁是 `$XDG_RUNTIME_DIR/ziggurat-instance-<id>.lock` 上的 `flock`，端点是同目录的 Unix stream socket。运行目录必须存在、属于当前用户且对其他用户关闭（mode 无 group/other 位），否则返回 `RuntimeDirectoryUnavailable` 或 `RuntimeDirectoryUnsafe`，不回退到共享位置。primary 持锁后替换崩溃留下的 socket；每个连接另用 `SO_PEERCRED` 核对 uid。进程退出时内核释放锁；lock 文件保留，避免并发 claim 锁住已删除的 inode。同一用户的多个会话共享运行目录，因此共享一个 primary。
- **Windows**：端点名为 `\\.\pipe\ziggurat-instance-<用户 SID>-<会话>-<id>`，每用户每会话一个。以 `FILE_FLAG_FIRST_PIPE_INSTANCE`、单实例、拒绝远程客户端创建，DACL 只授予当前用户；管道句柄本身就是锁，进程结束即释放。primary 用 `GetNamedPipeClientProcessId` 核对客户端进程的用户 SID，secondary 同样核对服务端进程，防止他人抢注名称。所有 I/O 为 overlapped，等待同时监听停止事件，超时或停止时取消并回收 I/O。secondary 确认前调用 `AllowSetForegroundWindow(primary)`，使 primary 能把窗口带到前台。

`instance.testing.sendRaw` 只供集成检查发送未校验字节，不用于应用。

## 登录启动

`integration.setLoginItem(.{ .id, .name, .executable, .arguments }, scope)` 让应用在用户登录时启动：Windows 写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 中名为 ID 的值，命令行按常规 argv 规则加引号；Linux 写 `$XDG_CONFIG_HOME/autostart/<id>.desktop`，Exec 按 Desktop Entry 规范转义。`removeLoginItem(id, scope)` 删除，重复删除无副作用；`loginItemRegistered(id, scope)` 只报告本应用自己的条目是否存在，不读取 Windows「启动应用」等桌面开关。可执行文件必须是绝对路径（Windows 为 `.exe`），参数最多 32 项、单项 1024 字节，拒绝控制字符。

## URL scheme 与文件关联

```zig
const app: system.integration.Application = .{
    .id = "org.example.Notes",
    .name = "Example Notes",
    .executable = "/opt/notes/bin/notes",
    .url_schemes = &.{"example-notes"},
    .file_types = &.{.{ .extension = ".exnote", .mime_type = "application/x-example-note", .description = "Example note" }},
};
_ = try system.integration.register(allocator, app, .{});
```

`register(allocator, application, options)` 写入按用户的处理程序注册，不请求提权，也不写机器范围。它是阻塞的磁盘/注册表操作，供安装程序、首次运行步骤或应用 worker 调用，不在 UI 回调里执行；同一值重复调用结果相同。`unregister` 以同一值删除它写入的内容，缺失项不是错误。全部输入先校验再写：scheme 为小写 RFC 3986 名称（最多 16 个、不重复），扩展名为小写 `.ext`（最多 64 个），MIME 为 `type/subtype` token，文本拒绝控制字符。

系统以 `<executable> <url>` 或 `<executable> <path>` 启动应用。结合单实例，第二个进程把这些参数转发给 primary。Linux 桌面启动器可能传 `file://` URL，`integration.localPath(argument, destination)` 把本地文件 URL 解码为路径，其他参数返回 null。

- **Windows**：scheme 写 `HKCU\Software\Classes\<scheme>`（`URL Protocol`、`DefaultIcon`、`shell\open\command` 为 `"exe" "%1"`）；文件类型写 ProgID `<id>.<ext>`（ID 加扩展名不超过 39 字符），并加入 `.<ext>\OpenWithProgids`。每个键带 `ZigguratApplicationId` 值，unregister 只删除标记属于本 ID 的键；扩展名的默认 ProgID 仅在等于本 ProgID 时清除。`make_default`（默认 true）设置扩展名默认 ProgID 并接管已存在的 scheme；为 false 时不覆盖其他应用的 scheme。Windows 在「设置」中保存的、受哈希保护的用户选择优先，任何注册 API 都不能覆盖，`register` 不尝试绕过。完成后发送 `SHCNE_ASSOCCHANGED`。
- **Linux**：写 `$XDG_DATA_HOME/applications/<id>.desktop`（`MimeType` 包含 `x-scheme-handler/<scheme>` 与各 MIME，Exec 为 `<exe> %U`），文件类型另写 `$XDG_DATA_HOME/mime/packages/<id>.xml` 声明扩展名 glob。`$XDG_CONFIG_HOME/mimeapps.list` 只改本 desktop ID 自己的条目：加入 `[Added Associations]` 首位，`make_default` 时加入 `[Default Applications]` 首位，并从 `[Removed Associations]` 移除；其他行逐字节保留，unregister 只移除本 ID。文件均先写同目录临时文件、fsync 后 rename。`refresh_caches`（默认 true）在 `/usr/bin` 或 `/bin` 存在时运行 `update-desktop-database` 与 `update-mime-database`，结果见返回的 `Report`；缺工具时扩展名 glob 要等系统下次重建 MIME 数据库才生效。

`Scope.data_home/config_home` 只在 Linux 替换 XDG 根，用于打包暂存或隔离测试。这里写的 `<id>.desktop` 就是应用的按用户 desktop entry，`Application.icon`、`categories` 也写入其中；打包工具可直接调用 `register` 安装它。

## 阻止休眠

`power.Assertion.acquire(.{ .kind = .system, .reason = "导出视频" })` 返回一个拥有的断言；`.display` 另保持显示器常亮。每个 owner 持有自己的原生对象，由 OS 合并，最后一个释放后系统才可休眠。`release()` 幂等，可在任意线程调用；不可复制。

- **Windows**：`PowerCreateRequest` 加 `PowerRequestSystemRequired`（display 另加 `PowerRequestDisplayRequired`），reason 显示在 `powercfg /requests`。release 清除请求并关闭句柄。
- **Linux**：在 system bus 上调用 systemd-logind `Inhibit`，`what` 为 `sleep` 或 `sleep:idle`，mode 为 `block`；返回的文件描述符就是 inhibitor，release 关闭它。这是一次阻塞调用，受 `timeout_ms`（默认 1000）约束；不能接受这段延迟时在 worker 上获取。错误区分 `ServiceUnavailable`（无 bus 或无 logind）、`AccessDenied`、`Timeout` 与其他失败。桌面是否因 `idle` inhibitor 停止熄屏取决于桌面环境。

## 任务栏与 dock

`taskbar.Taskbar.init(id)` 在 App owner 线程创建，所有方法和 `deinit` 都在该线程。

- `setProgress(window, progress)`：`none`、`indeterminate`，或 `normal/paused/failed` 的 0…1 分数；越界或 NaN 返回 `InvalidProgress`。
- `setOverlay(window, icon, description)`：Windows 叠加图标，图标只在调用期间借用、由 shell 复制，null 清除。
- `setBadgeCount(window, count)`、`setAttention(window, urgent)`：Linux launcher entry 的计数与提醒。

Windows 使用一个 `ITaskbarList3`，状态按窗口生效，窗口销毁后由 shell 丢弃；任务栏按钮存在之后 shell 才接受设置，隐藏窗口上可能返回 `TaskbarUnavailable`。Windows 只向打包应用开放数字 badge，因此 `capabilities.taskbar.badge_count` 在 Windows 为 false。Linux 在 init 时同步连接 session bus，每次变化发出 `com.canonical.Unity.LauncherEntry.Update`，对象为 `application://<id>.desktop`，作用于整个应用；该协议没有 indeterminate/错误状态，indeterminate 显示为 0。发出信号只表示已交给 bus，dock 是否支持该协议由桌面决定；之后才启动的 dock 只能看到下一次变化。GDBus 自身的 worker 线程属于系统库成本。

任务栏菜单（Jump List、dock menu）尚未实现，见 D03。

## 验证

`zig build test-system-integration` 覆盖转发帧的往返与恶意输入（截断、多余字节、魔数、超长、计数、越界长度、NUL、容量）、身份规则、XDG 与 user-dirs 解析、desktop entry/autostart/MIME XML 转义、mimeapps.list 编辑的幂等与外来行保留、Windows argv 引号往返、file URL 解码和电源参数校验。

`zig build smoke-os-integration` 启动真实子进程：8 个并发 secondary 与最大长度参数的转发、恶意/超长/停滞对端被拒后 listener 仍可用、primary 停止后旧 secondary 得到 `PrimaryUnavailable` 并可重新成为 primary、被杀死的 primary 释放锁、12 轮 claim/转发/停止后文件描述符或句柄数不变；Linux 另验开放权限的运行目录被拒。注册部分在隔离的 XDG 根中写入 scheme 与文件类型，用 GIO 独立解析默认处理程序和扩展名类型，再由 GIO 真正启动注册的 `%U` 命令，验证深链与文件参数经单实例转发到 primary，最后 unregister 并确认无关的 mimeapps 行保留；登录项写入、查询与删除。Windows 对应用 `AssocQueryStringW` 与 `ShellExecuteExW` 走同样的链路。Linux 用私有 bus 上的 logind 替身核对 Inhibit 参数和 release 后描述符真正关闭（12 轮），并用独立订阅者核对 launcher entry 的进度、计数和提醒；Windows 做 12 轮成对电源请求，句柄数不变。D-Bus 部分需要 session bus 且把同一地址作为 `DBUS_SYSTEM_BUS_ADDRESS`；`-- --require-dbus` 在缺失时失败而不是跳过。

这些检查不点击系统 UI，不验证 dock 的实际显示、真实 logind 策略或 Windows 用户选择对话框；Windows 任务栏只在隐藏窗口上调用，结果按 shell 是否接受记录。
