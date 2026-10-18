# 路线图

本轮按下面原有八项顺序完成了可运行的基础切片。勾选表示对应 API、实现、失败路径和列出的验证已经落地，不代表成熟控件库、所有平台能力或未执行的人工体验验证。

## 可构建真实工具窗口

| 状态 | 原定范围 | 已落地与验证 |
| --- | --- | --- |
| 已实现 | 错误诊断、应用图标、打包清单和系统窗口行为 | 结构化 sink、现场原生码、窗口动作、DPI 图标生命周期、VERSIONINFO/manifest、依赖清单；diagnostics/packaging/native-reentry smoke |
| 已实现 | 布局、裁剪、滚动、文本/输入法、编辑、字体 fallback 与可访问性 | 有界布局/命令/clip、scroll、UTF-8 编辑/历史/preedit、Windows IMM 与 Linux GTK IM、系统字体、可选 UIA；unit/editor/accessibility/Linux smoke |
| 已实现 | 绘制命令、D3D11、设备丢失、GDI 后备与可见窗口性能基线 | 同一命令列表回放、硬件/WARP、独立 swapchain 子窗口、设备丢失重建、一次性就绪等待与重绘合并；真实像素/回退/关闭检查及可复现 benchmark |
| 已实现 | 第二桌面平台验证 App/Window/Content 与 capability | GTK3/GLib/Cairo/Pango 实际运行、Unicode/IM、窗口回收和调度、X11 实测 2x；不支持能力显式失败 |

## Web 应用与工具链

| 状态 | 原定范围 | 已落地与验证 |
| --- | --- | --- |
| 已实现 | 编译期服务与 TS 客户端、版本、请求、错误、取消、隔离、流与背压 | 固定槽和随机 session、严格类型/大小检查、累计 ACK；Zig/Bun 测试和真实 WebView 生成客户端闭环 |
| 已实现 | 本地资源、来源/frame、导航、弹窗、下载、权限与崩溃恢复 | 固定 HTTPS 来源、内存响应、默认拒绝/notify、缓存 grant 重置、process_failed 和显式 recover；真实 Runtime 策略 smoke |
| 已实现 | 开发资源热更新、发布嵌入、按需系统菜单/对话框/剪贴板/托盘 | 目录事件→应用 worker 快照→主线程事务 reload、内容寻址嵌入；Windows 菜单/tray/clipboard 和四种 WinRT async picker；真实资源/系统/cancel-close smoke |
| 已实现 | 跨平台 CI、分发签名、更新与可复现体积/启动/内存/交互基准 | Windows/Linux workflow、真实测试证书 Authenticode、Ed25519 归档与不可变版本发布、Windows/Linux benchmark；本地验证，远端 workflow 尚未执行 |

## 保留的能力边界

- 基础 Editor 保留 Unicode scalar 与逻辑行接口；可选系统 Layout、ShapedEditor 和 DocumentEditor 已实现字素、bidi、软换行、视觉 caret 与同一正文的准备绘制/原生文本桥接。TSF、成熟字段与真实语言引擎继续按 T02 验收。
- 基础控件 UIA 保留其有界逻辑范围；可选文档与 Diff 辅助模块已验证完整文本、同一 Prepared 点定位、真实空 caret 和有界 owner 动作。完整语言单位、其他平台语义及屏幕阅读器兼容性继续按 T06/V03 验收。
- 文件选择器已验证四类原生启动、取消和关闭，尚未自动操作对话框完成选择/保存确认。真实 IME 语言引擎输入和视觉质量同样需要单独的交互验证。
- Linux 已有原生窗口、自绘、IM 和可选 WebKitGTK 的可信 HTML、持久 Profile、CookieStore、custom/远程资源策略与 PageSession；菜单、托盘、选择器和剪贴板扩展继续按 P02 实施。Windows/Linux 已有唯一 Content Owner 的矩形页面区域与跨宿主 DOM；任意遮挡和完整混合输入仍属 H02/H03。macOS 尚无运行后端。
- CI 配置与本地等价检查不等于远端 CI 已运行。性能计时是宿主首次 paint、CPU 提交、同步动作和每轮至少 30 秒空闲区间，不是输入到屏幕延迟、长期空闲零 CPU 或产品启动承诺。
- 更新模块提供验签、流校验和版本发布，网络、重启、保留策略、密钥轮换和增量更新由宿主或后续模块负责。项目已选择 MIT，源码与分发使用根目录 LICENSE；测试 fixture 保持仅用于测试。

## 完整功能实施计划

基础切片之后的功能扩展已经纳入[完整功能实施计划](implementation-plan.md)，不再作为无验收条件的候选方向。计划逐项记录状态、依赖、实际平台和验证证据；未完成项不能因所属基础模块已经存在而勾选。

推进顺序是窗口与协议契约、基础控件与绘制、复杂文本与数据视图、页面与混合内容、系统与文档集成、平台补齐、可选生态及分发更新。不同模块的独立切片可以并行，影响同一生命周期或原生 ABI 的变更顺序整合。

W01/W02 窗口几何与拥有/模态关系、U01/U02.1 选择/范围控件与键盘导航、U03.1 网格、I01 类型化事件、I02 编译期服务调度、S01 Windows 快捷键与通知区通知、E01 显式扩展生命周期已有对应验收。绘制已有严格渐变、图片/path/阴影、有界分组、独立离屏、软件可选色彩插值与显式高斯准备；完整 SVG、GPU 新插值和实时滤波等仍按 G01–G04 分项实施。各项准确平台、预算、失败路径与证据以实施计划为准，基础模块存在不表示父项已完成。

后续已落地的独立切片包括 W03.1 窗口装饰/命中/原生交互、T01.1–T01.3 系统文本布局/准备绘制/编辑器桥接、T03 有界文档与视图、B01.1/B01.2 本地及远程页面、B05 显式文件/异步响应与生产者背压，以及 S02.1 显式 worker 进程启动和 Windows 小图标。透明/材质、成熟编辑器、完整页面/混合策略、平台补齐和完整 Shell 能力分别保留后续验收。

实现与验证入口见 [架构](architecture.md)、[性能](performance.md)、[打包](packaging.md)、[IPC](ipc.md)、[资源工具](web-assets.md)、[系统设施](system.md) 和 [更新](updates.md)。
