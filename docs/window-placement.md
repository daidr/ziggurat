# 窗口放置与状态存储

`ziggurat_window_placement` 是只依赖核心的可选模块。纯 `model`、`codec` 和 `Files` 不依赖 UI、WebView 或 renderer；它们也可单独导入。模块没有全局状态、allocator、后台线程、自动存盘、轮询或绘制期磁盘访问。

它提供有界显示器快照、正常客户区跟踪、工作区约束、离屏恢复、显示器变化后的可达性判断，以及版本化存储和真实窗口应用。模块自身不注册显示器变化通知；宿主用 `system.desktop.Watch` 订阅 monitors 变化，在回调里调用 `refresh` 与 `displacement`，再决定是否重新放置，见下文“显示器变化”。

## 坐标与约束

```zig
const topology = try placement.refresh(window);
var tracker = placement.Tracker.init();
try tracker.confirmNormal(window, &topology);
const saved = try tracker.snapshot();
```

客户区宽高始终为整数 DIP。位置与显示器 `bounds/work` 使用原生桌面坐标：Windows 为物理像素，X11 为 GTK application pixels。X11 的 framebuffer scale 为 2 时，桌面坐标仍为逻辑单位，`units_per_dip` 为 1；不能再把位置和工作区乘以 2。Wayland 不提供本模块要求的位置能力，`refresh` 明确拒绝。

`Topology` 拥有内联的最多 64 项快照，不借用原生 monitor 对象；查询不分配框架堆存储。每项记录完整显示器范围、排除任务栏等区域的 workarea、primary 和有界 UTF-8 key。Windows key 来自原生显示设备名称，X11 key 包含枚举位置与显示器 model。这些是辅助匹配值，不能当作永久硬件身份、EDID 身份或跨机器稳定标识。

`model.resolve` 优先匹配辅助 key；失效后按旧矩形的最大交集、到工作区的距离、primary 和枚举顺序选择。坐标空间不同时忽略旧位置并从 primary 恢复。同一 key 保留相对旧 workarea 的 DIP 偏移，并按目标的真实比例转换；移除的显示器则居中。负坐标合法。

正常 DIP 尺寸保持不变，过大时按目标 workarea 和原生 frame insets 缩小；位置夹紧到整个 frame 可容纳的范围。`Constraints` 的 min/max 由宿主显式提供，须与 `WindowOptions` 的业务约束一致。不可同时满足最小尺寸与工作区时返回 `ConstraintsUnsatisfiable`，不会用无效尺寸绕过核心限制。纯模型接受显式 `Metrics`；运行期使用目标上的真实窗口比例和装饰几何，不把当前显示器的 DPI 当作另一显示器的 DPI。

## 正常矩形与特殊状态

Tracker 是调用者持有的主线程值，在每次方法调用期间保持地址稳定。它没有回调注册、保留的 Window 或待释放的 native 资源。App 必须覆盖每次传入 Window 的使用；已捕获的纯 State 可以在 App 关闭后继续存储。

`observe` 在普通状态更新正常矩形；最大化、最小化、全屏或待进入全屏期间只更新模式，保留旧矩形。刚创建 Tracker 时若窗口已经特殊化、从未观察过正常几何，返回 `NormalBoundsRequired`。模块不会短暂恢复用户窗口来猜测它的正常矩形。

原生状态和配置事件不是一个原子快照。特殊状态回到普通状态后，`observe` 返回 `normal_pending`，继续保留上次正常矩形；宿主确认自己的 WM/布局观测后显式 `confirmNormal`，再恢复普通跟踪。不能把任意一个早到的 state flag 当作全部配置已经完成。

捕获也会对照实际原生 client 与核心的客户区报告；GTK 仍回显待完成请求而原生窗口尚未匹配时返回 `GeometryPending`，保留旧快照，等待下一个真实几何事件。

存档保留正常矩形、坐标空间、原工作区、当时的比例、辅助 key，以及 maximized/fullscreen/always-on-top。全屏可同时保存进入前的 maximized 状态。最小化不作为下次启动状态；可见性、焦点、owner/modal、Content、运行期 Window ID 均由应用重新建立。

## 应用与原生确认

```zig
var restore = try placement.Restorer.init(window, saved, topology, .{});
switch (try restore.advance()) {
    .waiting => {},
    .needs_show => try window.perform(.show),
    .complete => {},
}
```

`Restorer` 是稳定的主线程值。它借用 Window 的 App 生存期，拥有 State/Topology 的值快照，无需析构。`cancel` 阻止后续操作；已接受的原生移动或状态变化不会回滚。窗口关闭、错误或取消后可检查 `phase/plan`，成功只在实际观测满足契约后返回。

宿主根据真实 resize/state/position 事件推进。事件可能同步发生在 `Window.perform` 或设置几何的方法内，此时核心更新事务仍 Busy；正式夹具通过合并一次 `App.post`，在该事务退出后推进。模块不自行排队、不泵消息，也不安排重复 timer。`waiting` 仅表示仍需原生事件；宿主自行提供合理 deadline 和取消策略。

状态机先退出全屏，再明确提交一次普通 restore。全屏退出可能异步恢复进入前的最大化，因此这一普通请求不以一个中间的 `maximized=false` 为省略依据。已提交的正常/最大化/全屏/置顶请求不会在每次事件中重复发送；晚到的中间状态只等待随后观测。

跨显示器时先提交一个有界的临时移动，使真正窗口落到目标，再查询其实际 DPI 并计算最终工作区约束。最终客户区、原生 client 几何和 frame 范围均须确认，才应用存档模式。对需要映射后才有 WM 几何的隐藏窗口，或即将恢复最大化的隐藏窗口，返回 `needs_show`；由宿主决定何时显示，模块不偷偷激活窗口。

每次调用持有 Window callback scope，重入同一 Tracker/Restorer 返回 `Busy`。关闭回调不会在这些方法尚使用宿主上下文时提前释放它。原生步骤可能部分成功；该事务不宣称跨 WM 操作的原子回滚。拓扑快照已经过期或原生归属发生变化时，宿主应显式刷新并用原 State 建立新 Restorer，不累积历史窗口记录。

## 显示器变化

```zig
var watch = system.desktop.Watch.init(&host, Host.desktopChanged);
try watch.start(app, .{ .monitors = true });

fn desktopChanged(context: *anyopaque, change: system.desktop.Change) void {
    const host: *Host = @ptrCast(@alignCast(context));
    if (!change.monitors) return;
    host.topology = placement.refresh(host.window) catch return;
    switch (placement.displacement(host.window, &host.topology) catch return) {
        .offscreen => host.restorer = placement.Restorer.init(host.window, host.tracker.snapshot() catch return, host.topology, host.constraints) catch return,
        .special, .contained, .partial => {},
    }
}
```

`displacement` 只查询，不移动窗口：它读取当前原生 frame，对照宿主刚刷新的 `Topology` 分类。普通状态下，frame 完全落在某个 workarea 内为 `contained`；与某个 workarea 在两个方向上都至少重叠 `model.min_reachable`（48 个原生桌面单位，frame 更小时要求该方向完全重叠）为 `partial`；否则为 `offscreen`。最大化、最小化、全屏和待进入全屏都返回 `special`，这些 frame 由系统管理，Tracker 继续保留正常矩形。当前显示器不在传入的快照中时返回 `DisplayChanged`，表示快照已过期，应重新 `refresh`。

建议只在 `offscreen` 时重新放置。`partial` 可能是用户有意拖到屏幕边缘，是否收回由宿主决定。重新放置使用 Tracker 最近确认的正常状态建立新的 `Restorer`，按真实几何事件推进，规则与启动恢复相同：原显示器仍在时保留相对工作区的偏移并夹紧，显示器已移除时按重叠、距离和 primary 选择目标并居中。正在进行的 Restorer 应先 `cancel`，再用新快照建立。

Windows 在显示器移除时通常自己把窗口移到剩余显示器；X11 窗口管理器（如 Openbox）通常把越界窗口夹到可见边缘，此时结果是 `partial`。模块不假设任何一种行为，只报告观测到的结果。`refresh` 与 `displacement` 都在 owner 线程同步执行，不分配，也不注册回调。

## 有界存储与 worker I/O

```zig
var entries: [16]placement.Entry = undefined;
var store = try placement.Store.init(&entries);
try store.put(try placement.Key.init("main"), saved);
var bytes: [placement.codec.max_bytes]u8 = undefined;
const encoded = try placement.codec.encode(&store, &bytes);
```

Store 借用调用者 Entry 数组，最多 256 项。业务 key 为非空 UTF-8，最长 96 字节，不能包含 NUL。get/put/remove 线性有界；它不是全局窗口数据库。调用者负责串行访问。正常更新、查询、放置和编解码不使用 allocator，因此没有隐藏 OOM 路径。

二进制版本 1 使用固定小端 header/record，记录长度和条数均明确，并以 CRC32 检测意外损坏。未知版本、错误长度、额外尾字节、无效 UTF-8、未知 flags、非有限比例、非法几何、重复 key 与 checksum 错误均明确拒绝。它不是签名或不可信来源的认证机制。解码先完整验证至有界栈候选，最后一次替换 Store；容量或损坏失败保留旧内容。编码在容量和语义检查通过前不改输出。最大文件为 61,456 字节。

```zig
// 宿主显式 worker 内；主线程会返回 UiThreadIo。
const files: placement.Files = .{ .ui_thread = app.owner };
try files.save(directory, "placement.bin", owned_encoded_bytes, write_buffer);
const loaded = try files.read(directory, "placement.bin", owned_read_buffer);
// 结果及缓冲保持到主线程接收；用 App.post 返回后再 codec.decode。
```

Files 只借用 Dir、文件名和调用缓冲，不创建/保留 worker 或默认目录；线程的取消、join、缓冲寿命和投递 Full/Closed 责任属于宿主。磁盘方法拒绝在指定 UI 线程调用。文件名限单个相对名称，不接受绝对路径、目录分隔符或 `..`。

save 在同一目录创建独占临时文件，写入、flush、file sync 后原子替换目标；失败清理临时文件，旧目标保留，宿主可保留快照并显式重试。它不承诺目录项断电持久化，不会悄悄吞掉读取/替换错误。读取上限和调用缓冲均有界，长度在读取中变化会拒绝；内容校验和版本拒绝仍在 owner 解码阶段执行。

## 验证与尚未覆盖的范围

`zig build test-window-placement` 覆盖负坐标、辅助 key 失效、跨坐标空间、不同原生比例、工作区/装饰/最小尺寸、10,000 组独立包含关系检查、整数端点、最大容量、逐字节损坏、语义损坏、版本和输出事务，以及真实 worker 原子替换失败后重试。

`zig build smoke-window-placement` 使用真实 Win32 或 GTK/X11。Windows 在未激活的独立 desktop 子进程中运行，父进程等待子进程退出后释放 desktop。Linux 使用隔离 Xvfb/Openbox 和 `-- --require-wm`，另以 `GDK_SCALE=2` 验证。闭环包括离屏恢复、原生 frame 包含工作区、max/full 保留正常矩形、worker 保存读取、窗口销毁重建后恢复、实际状态/几何确认、普通/raw 关闭重入与最终 records=0。

同一 smoke 还把已恢复的窗口移到所有显示器之外：Win32 接受越界位置，期望 `offscreen`；Openbox 把 frame 夹到可见边缘，接受 `partial`。随后以 Tracker 快照恢复，检查 frame 回到 workarea、`displacement` 为 `contained`，最大化期间为 `special`。

`zig build smoke-window-placement-displays`（仅 Linux，需隔离 Xvfb 与窗口管理器，由 `scripts/linux-window-state.sh` 最后运行）用 RandR 把 Xvfb 唯一输出的 CRTC 缩小一半，产生真实的显示器几何变化。窗口事先放在原显示器右下四分之一，缩小后不再被覆盖。只有 `system.desktop.Watch` 的 monitors 回调能推进检查，之后 `refresh` 读到新尺寸，`displacement` 为 `offscreen`，Restorer 把窗口放回新的 workarea。1x 与 `GDK_SCALE=2` 均已在本地通过，结束时恢复原模式。

没有以这些检查声称已经验证真实热插拔、多台物理显示器的混合 DPI、全部 WM、Wayland 定位、macOS 或视觉质量。Windows 的显示器变化只在交叉编译中检查，没有在真实系统上改变显示器配置；更广的存储迁移继续属于后续切片。
