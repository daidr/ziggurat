# 性能约束与验证

## 实现约束

- 空闲等待原生事件；重绘请求由系统合并，输入动作独立于重绘执行。
- 核心 256 项有界 MPSC 队列，正常投递/调度不做堆分配；每类消息有有限批次。
- 窗口槽位查找、移除和复用 O(1)，记录随关闭回收；元数据随并发窗口峰值保留。
- 销毁与最终 native cleanup 使用独立侵入链表，不消耗业务队列容量，退出时清空。
- 16 个 one-shot 原生等待槽；GPU 忙时登记就绪事件，等待期间合并重绘，不用定时器反复尝试。
- 每帧命令/文本/clip/命中表有明确预算；布局、命令记录和已初始化的编辑操作不做每帧 Zig 堆分配。
- GDI/Cairo surface 与字体资源复用；D3D11/D2D/DirectWrite 按 Context 拥有资源，设备丢失后重建。
- WebView 资源从内存读取；磁盘快照使用应用管理的 worker，初始化时排序元数据，资源请求二分查找。
- 核心不依赖内容模块；纯自绘构建不编译 WebView 适配或安装 Loader。IPC JSON/UTF 转换等分配明确使用调用者 allocator。

这些是实现约束。系统字体、图形和浏览器 API 可以在内部申请资源；没有把它们计作零分配，也没有据此推导所有场景的性能。

## 功能与回收证据

2026-10-16，Windows x86_64 / Zig 0.15.2：Debug、ReleaseSafe、ReleaseSmall 的 test/check 通过；核心、系统与 WebView 的相关 native smoke 已运行。核心窗口、可访问性、GPU 等新关闭路径在修改后重新验证。Linux 在 WSL Ubuntu 24.04 的真实 GTK 桌面运行，另用 X11 的实际 scale=2 验证 DPI。

| 检查 | 已覆盖 |
| --- | --- |
| test/check | 生命周期与故障注入、布局/clip/scroll/编辑、协议、资源快照、打包、更新签名与 OOM 清理；普通目标后端编译 |
| smoke/lifecycle | 1,000 次创建/绘制/关闭、槽位复用、关闭否决与回调、GDI/USER 基线恢复 |
| waitables/cleanup/reentry | native 队列配额、持续任务下的公平性、借用 HANDLE 取消、未回复 SendMessage 中的最终释放延期、外部 raw destroy |
| editor/routing | UTF-16 消息、preedit cancel、IMM 候选位置、编辑器失焦到按钮首次点击和多编辑器路由 |
| accessibility/ui-config | 实际 MTA UIA 属性/动作/选择、断连重入、关闭后 retained COM、冻结配置与 native 计数归零 |
| gpu/fallback | 硬件与 WARP 像素/clip/文本/DPI/resize、注入设备丢失、同命令 GDI 后备、就绪回调与待等待窗口关闭 |
| text/layout/shaped editor | 原生布局差分、可见覆盖、双 affinity/选区、预算与 OOM、真实输入/resize/候选 caret；draw/hit/caret 只读快照 |
| images/prepare/drawing | 真实 PNG/JPEG/EXIF、crop/预乘/mip、三后端像素、上传事务/预算/LRU、Frame 与驻留 pin、设备恢复与原生引用归零 |
| system/picker/result | 菜单/托盘 12 轮资源恒定、四类 WinRT async cancel/关闭；ABI 替身成功结果、UTF-16、多选、容量、跨代重入与 self-free 回调 |
| webview/policy/ipc/assets | 15 Apps、99 次初始化中关闭、真实页面策略/缓存权限/崩溃恢复、生成客户端 ACK/取消、目录变更到 DOM 重载；适配层 COM 归零 |
| packaging/signing/update | 确定 ZIP、真实测试证书 store/PFX、签名破坏拒绝、签名归档到独立版本目录并实际启动新 EXE |
| smoke-linux | GTK/Cairo/Pango、Unicode/IM、外部销毁、槽位复用、256 跨线程任务和持续任务公平性；native 计数归零 |

例如最终 ReleaseSafe 原生生命周期检查中，GDI 12→12、USER 6→6，窗口记录为零、槽位保持 1；投递 9,998 条消息后触发配额错误，已接受任务仍执行一次。UIA 修复后串行重复检查原生 state/provider/range/action 全部归零。资源计数分别覆盖各适配层，不等于系统浏览器进程与图形驱动全部内部内存。

真实 IME 语言引擎输入、屏幕阅读器体验、picker GUI 成功选择、视觉质量没有自动验收。macOS 的 check 只证明编译边界。CI YAML 经 actionlint 与本地等价命令验证，远端 workflow 尚未执行。

系统文本的构造成本与正常 paint 分开。Windows 快照使用真实 cluster/range 与逐 run 校验，复杂或非精确坐标继续查询原生布局；同构建的 layout/layoutReference、position/range/fallback 次数和 scratch 峰值由 `smoke-text-layout` 一起输出。长行优化不能推导多段落或全部脚本同等加速，测量与限制见[系统文本布局](text-layout.md)。准备覆盖仅限当前 viewport，不为长文档创建完整像素平面。

静态图片的 decode、crop/预乘/mip、显式 upload 与命中回放分别计费。32 项驻留 LRU 按像素 payload 预算，候选上传成功后才淘汰旧项；`peak_reserved_bytes` 是候选与旧驻留同时存在的保守预留量，不是驱动显存测量。设备丢失恢复重新上传有界驻留集合，并单独计数；正常命中绘制不生成 mip、不创建纹理。详见[图片准备与绘制](image-drawing.md)。

## 基准方法与复现

工作量固定为 640×480 DIP、256 个矩形、UTF-8 标签和按钮；首次绘制后预热 16 帧，再测 200 次同步提交。每个配置启动六次，逐次保留 P50/P95/P99，文档表格取六个对应统计量的中位数。系统缓存未清空，这组连续启动数据不代表受控冷启动。

Windows 用 WM_PAINT 同步返回计时，GPU 异步提交不等待显示完成。`first_paint_ns` 从 App.init 前到首次 paint 返回；额外的 `first_paint_since_process_start_ns` 使用内核创建 FILETIME 与首次 paint 后的精确系统时间，包含进入 main 前的时间。系统时钟计时与单调 CPU 提交计时分别记录。100 次同步鼠标动作记录总耗时，动作均必须执行；不包含系统输入排队与显示延迟。

Linux 在实际 GTK 窗口上下文初始化后，把同一 draw signal 提交到复用 Cairo image 目标，另有可见窗口的自然绘制。`first_paint_ns` 只覆盖框架初始化到首次同步 draw 返回，明确没有测进程创建时间。两平台的绘制目标与字体实现不同，不据此做平台性能排名。

每次完成工作量后先稳定 200 ms，再在主循环运行时采样至少 30 秒进程 CPU。只有应用拥有的测量 worker 等待和 sleep，主线程继续等待原生事件。worker 在 UI 确认采样开始后才计时，默认快速检查仍为 500 ms。CPU 比例相对一个逻辑核；时间分辨率内的 0 不等于物理上没有工作。

内存字段是在工作量完成后、进入闲置采样之前读取的 Windows 工作集/私有字节或 Linux /proc 进程值，不是长期峰值或采样末尾的内存。217 个显式工作量提交与全过程实际帧数分开记录，自然 paint、回退、GPU busy 与合并都保留计数。

```powershell
./scripts/benchmark.ps1 -Renderer gdi,hardware,warp -Repetitions 6 `
  -Optimize ReleaseSmall -Visible -IdleMilliseconds 30000 `
  -OutputDirectory zig-out/benchmarks
```

```sh
# 原生 Linux / 已安装 GTK 与 Zig 0.15.2
mkdir -p zig-out/benchmarks
for sample in 1 2 3 4 5 6; do
  GDK_BACKEND=x11 GDK_SCALE=1 zig build benchmark -Doptimize=ReleaseSmall -- \
    --visible --idle-ms 30000 --output "zig-out/benchmarks/linux-$sample.json"
done
```

WSL 还需 `--cache-dir` 指向 Linux 文件系统。Windows driver 保存机器、工具链、命令、选定源文件与可执行文件 SHA-256；Linux JSON 保存 kernel、GTK/Pango/Cairo、display backend、scale，旁附可执行文件与源摘要。CI 的一次短采样用于功能回归，不替代这组六次长采样。

显式共享 GPU 设备域另有[多窗口测量工具](gpu-performance.md)，对1/4/8个真实隐藏窗口分别记录共享/独立创建、CPU提交、物理引用和逻辑资源。它不等待 GPU 或显示完成，与上面的 UI 主循环/闲置测量使用不同范围。

## 仿射合成独立基准

Linux 可选 `benchmark-affine-cairo` 不创建窗口，也不接入默认 test/check 或应用依赖。它只链接纯采样模块和一份 Cairo 原生测试单元；`native_*` 字段表示测试专用的旧 Cairo 路径基线，不是另一种生产后端或 GPU 数据。构造、源像素准备和 CLI 分配均在计时外。

```bash
source scripts/linux-cache-env.sh
configure_linux_cache "$PWD" affine-benchmark
zig build benchmark-affine-cairo -Doptimize=ReleaseFast -j1 \
  --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" -- \
  --pilot --matrix oblique
```

去掉 `--pilot --matrix oblique` 使用完整 378 情景：3 种物理尺寸、3 个 DPI、7 种矩阵、1/2/4 层和两种源 alpha。默认每项预热 4 对、采样 21 对，分别输出 median/p95、flush/borrow/draw/finish、实际像素访问、预热后本层对象创建和最终资源计数；阶段中位数之和不等于总耗时中位数。`--samples`、`--warmup` 和 `--matrix` 可缩小检查，`--help` 列出完整参数。

正式采样前停止其他编译与原生测试，保留命令、源码/可执行文件摘要和完整输出。构建负载下的短 pilot 只能检查入口和资源回收。这里测 CPU 图像目标上的 scope 完成，不包含 source 绘制、窗口呈现、GPU 等待或输入到显示延迟；对象计数也不覆盖 Cairo 内部的全部分配。当前共享采样器在部分缩放和平移下仍比该基线慢，实测范围及 GPU 后备限制见[仿射绘制](affine-rendering.md)，未据此宣称性能已经收口。

## 分发体积

同日 Windows x86_64 / ReleaseSmall 独立前缀构建，图标与 manifest 已包含在 EXE：

| 产物 | 字节 |
| --- | ---: |
| GDI 自绘计数器 | 68,608 |
| 启用 D3D11 与 UIA 的计数器 | 101,888 |
| WebView 计数器 | 92,160 |
| WebView2 Loader DLL | 194,912 |
| 九尺寸 PNG ICO 输入 | 4,181 |

自绘与 WebView 依赖独立；系统 DLL、GTK 与 WebView2 Runtime 不在以上 EXE 字节内。基准程序包含额外 JSON/CLI/测量逻辑，其体积单独保存在原始结果，不能代替产品体积。

## 实测基线

正式原始样本见 [Windows 六次长采样](benchmarks/2026-10-16-windows.json) 与 [Linux 样本目录](benchmarks/2026-10-16-linux/)。实际机器为 AMD Ryzen 7 9800X3D、16 逻辑核；Windows NT 10.0.26220 枚举到 RTX 5080、AMD 和虚拟显示适配器，硬件模式由系统选择默认 D3D11 adapter。Linux 为 WSL2 6.6.87.2、GTK 3.24.41、Cairo 1.18.0、Pango 1.52.1、GdkX11Display、scale=1。系统环境和驱动变化后须重新测量。

Windows 六轮长采样中位数如下；提交分位数的单位为微秒：

| 模式 | 进程→首次 paint | App→首次 paint | 提交 P50 / P95 / P99 | 100 次同步动作 |
| --- | ---: | ---: | ---: | ---: |
| GDI | 56.87 ms | 34.12 ms | 537.00 / 908.85 / 1306.05 µs | 79.00 ms |
| 硬件 D3D11 | 289.63 ms | 268.27 ms | 215.15 / 1745.30 / 3477.60 µs | 93.33 ms |
| WARP | 123.88 ms | 102.98 ms | 238.10 / 552.85 / 885.50 µs | 84.08 ms |

| 模式 | 工作集 / 私有字节 | 闲置进程 CPU / 实际区间 | 单核比例 |
| --- | ---: | ---: | ---: |
| GDI | 14.37 / 2.83 MiB | 23.438 ms / 30.012 s | 0.0781% |
| 硬件 D3D11 | 55.02 / 57.78 MiB | 31.250 ms / 30.009 s | 0.1041% |
| WARP | 47.73 / 19.15 MiB | 0 ms / 30.009 s | 0%（计时分辨率内） |

Windows 18 轮的每次工作量为 217 个显式提交；整个运行包含 218–221 次实际绘制，回退、GPU busy 和合并计数均为零。基准 EXE 为 308,224 字节，三种模式使用同一份包含 GPU 代码的工具。硬件模式较低的提交中位数与较高的启动、尾部及内存值分别保留，不合成一个速度倍数。

Linux 六轮长采样中位数如下；该列首次绘制只从 App.init 计时：

| App→首次 draw | 提交 P50 / P95 / P99 | 工作量后 RSS | 30 秒闲置 CPU | 单核比例 |
| ---: | ---: | ---: | ---: | ---: |
| 27.17 ms | 127.28 / 267.03 / 426.65 µs | 29.31 MiB | 0.287 ms / 30.013 s | 0.0010% |

六轮各有 217 个显式工作量绘制，整个运行分别记录到 220、219、219、219、219、219 次绘制。Linux 基准 EXE 为 86,904 字节；系统 GTK/Pango/Cairo 单独提供。

## 空闲内存与输入延迟

两个测量工具都需要桌面会话（Linux 可用 Xvfb），不接入默认 test/check 的运行，只编译。

`zig build idle-memory -Doptimize=ReleaseSafe -- [--count 3] [--idle 6] APP...` 依次启动每个应用，空闲 `idle` 秒后测量，共 `count` 次，以应用文件名为键输出各项中位数的 JSON：`{"hello": {"app": 字节, "total": 字节}}`。`app` 是应用进程本身，`total` 加上它启动的全部后代进程（WebView 的进程）：Linux 为 `/proc/PID/smaps_rollup` 的比例集大小（PSS，共享页只计一次），后代由 `/proc/*/stat` 的父进程号得到，测完发 SIGTERM，10 秒未退出则 SIGKILL；Windows 为任务管理器显示的私有工作集（`PROCESS_MEMORY_COUNTERS_EX2.PrivateWorkingSetSize`），后代来自 Toolhelp 进程快照（每个进程只计一次，防止父进程号被复用），测完结束应用及其后代，因为 Windows 没有让进程退出的信号。空闲期内退出的应用算失败。

`zig build input-latency -Doptimize=ReleaseSafe -- [--mode type,scroll,drag,anim] [--runs 6] [--events 300] [--warmup 30]` 测量输入从到达到“显示它的那一帧绘制完成”的时间。每次运行是一个独立进程，窗口内容是原生 `ui.Context`：逐字键入一行文字（字符间隔 60–140 ms）、用滚轮滚动一百万行的列表、拖动一个方块（后两者事件间隔 4–12 ms），或者没有输入的动画（anim）。事件由另一个线程经 `App.post` 送到主线程，再由 `Window.emitEvent` 交给窗口内容，与原生输入走同一条路径；事件以投递时刻为到达时刻，主线程忙碌的时间也计入。

显示某个事件的帧是主线程处理它之后绘制的下一帧，帧的完成时刻取帧统计的整帧耗时（录制、预检、回放与呈现）。每次运行输出延迟的平均值与 p50/p90/p99/最大值（毫秒），以及组成部分的平均值：等待主线程（queue）、处理事件（handle）、从处理完到帧绘制完成（paint，包含等待平台的下一次绘制）。Windows 与 GTK 在这里都不报告帧何时到达显示器，所以从呈现到屏幕的合成器时间不在其中。anim 输出帧间隔与每帧耗时。汇总取各次运行的中位数：比较不同构建时交替运行并比较中位数。

本地 Xvfb（Linux Debug 构建）两次运行的示例中位数：键入 1.4 ms（事件稀疏，平台立即绘制），滚动 10.3 ms 与拖动 9.4 ms（事件密集，与约 16.7 ms 的帧时钟合并），动画帧间隔 16.7 ms。这只说明工具可用，不是性能基线。

## 后续优化门槛

先扩大同时存活窗口、控件、文本和滚动场景，再用测量决定共享 GPU device、布局/文本缓存、批次和局部失效。输入到显示、浏览器全部进程、受控冷启动和长时间内存稳定性需要独立实验；本次数据不作这些结论。
